{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -freduction-depth=0 #-}

import           Data.Maybe (fromMaybe)
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Network.TypedProtocol.Pipelined (Nat (..))
import           Ouroboros.Network.Protocol.ChainSync.ClientPipelined
                   (ChainSyncClientPipelined (ChainSyncClientPipelined),
                   ClientPipelinedStIdle (CollectResponse, SendMsgDone, SendMsgRequestNextPipelined),
                   ClientStNext (..))
import           Ouroboros.Network.Protocol.ChainSync.PipelineDecision
import           System.Environment (getArgs)


-- TODO move this module into cardano-api
import           Cardano.Api
import           Cardano.Api.NewApiStuff
import           Cardano.Slotting.Slot (WithOrigin (At, Origin))
import           Control.Monad (when)
import           Data.Foldable
import           Data.IORef
import           Data.Word
import qualified Ouroboros.Consensus.Shelley.Ledger as Shelley

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Shelley.Spec.Ledger.API as Ledger
import qualified Shelley.Spec.Ledger.Rewards as Ledger
import qualified Shelley.Spec.Ledger.RewardUpdate as Ledger


main :: IO ()
main = do
  -- Get socket path from CLI argument.
  configFilePath : socketPath : _ <- getArgs
  rewardUpdatesByEpoch <- foldBlocks
    configFilePath
    socketPath
    mempty
    (\_env
      ledgerState
      _blockInMode
      rewardUpdatesByEpoch ->
        case ledgerState of
            LedgerStateShelley (Shelley.ShelleyLedgerState _ ls _) -> return (update ls rewardUpdatesByEpoch)
            _                                                      -> return rewardUpdatesByEpoch
    )

  let correctAggregation = Set.foldr ((<>) . Ledger.rewardAmount) mempty
      incorrectAggregation s = if Set.null s then mempty else (Ledger.rewardAmount . Set.findMin) s
      pairwisePlus (a, b) (c, d) = (a<>c, b<>d)
      allShelleyRewards =
        Map.foldr
          (Map.unionWith pairwisePlus)
          mempty
          (Map.map
            (Map.map (\s -> (correctAggregation s, incorrectAggregation s)) . Ledger.rs)
            rewardUpdatesByEpoch
          )
      isDeficient (correct, incorrect) = correct /= incorrect
      deficientShelleyRewards = Map.filter isDeficient allShelleyRewards

      displayCredential (Ledger.KeyHashObj (Ledger.KeyHash kh)) = "keyhash," <> show kh
      displayCredential (Ledger.ScriptHashObj (Ledger.ScriptHash sh)) = "scripthash," <> show sh
      dispReport (cred, (Ledger.Coin correct, Ledger.Coin incorrect)) =
        displayCredential cred
          <> ","
          <> show (correct - incorrect)
          <> ","
          <> show correct
          <> ","
          <> show incorrect

  putStr "type,hash,difference,proper,received\n"
  mapM_ putStrLn $ fmap dispReport $ Map.toList deficientShelleyRewards
  return ()

  where
    update ls rs =
      if Ledger.nesEL ls `Map.member` rs
      -- If we have already obtained this epoch's reward update
        then rs
        else case Ledger.nesRu ls of
               Ledger.SJust (Ledger.Complete ru) -> Map.insert (Ledger.nesEL ls) ru rs
               _ -> rs


-- | Monadic fold over all blocks and ledger states.
foldBlocks
  :: forall a.
  FilePath
  -- ^ Path to the cardano-node config file (e.g. <path to cardano-node project>/configuration/cardano/mainnet-config.json)
  -> FilePath
  -- ^ Path to local cardano-node socket. This is the path specified by the @--socket-path@ command line option when running the node.
  -> a
  -- ^ The initial accumulator state.
  -> (Env -> LedgerState -> BlockInMode CardanoMode -> a -> IO a)
  -- ^ Accumulator function Takes:
  --  * Environment (this is a constant over the whole fold)
  --  * The current Ledger state (with the current block applied)
  --  * The current Block
  --  * The previous state
  --
  -- And this should return the new state.
  --
  -- Note: This function can safely assume no rollback will occur even though
  -- internally this is implemented with a client protocol that may require
  -- rollback. This is achieved by only calling the accumulator on states/blocks
  -- that are older than the security parameter, k. This has the side effect of
  -- truncating the last k blocks before the node's tip.
  -> IO a
  -- ^ The final state
foldBlocks nodeConfigFilePath socketPath state0 accumulate = do
  (env, ledgerState) <- initialLedgerState nodeConfigFilePath

  -- Place to store the accumulated state
  -- This is a bit ugly, but easy.
  stateIORef <- newIORef state0

  -- Connect to the node.
  --putStrLn $ "Connecting to socket: " <> socketPath
  connectToLocalNode
    connectInfo
    (protocols stateIORef env ledgerState)

  readIORef stateIORef
  where
  connectInfo :: LocalNodeConnectInfo CardanoMode
  connectInfo =
      LocalNodeConnectInfo {
        localConsensusModeParams = CardanoModeParams (EpochSlots 21600),
        localNodeNetworkId       = Mainnet,
        localNodeSocketPath      = socketPath
      }

  protocols :: IORef a -> Env -> LedgerState -> LocalNodeClientProtocolsInMode CardanoMode
  protocols stateIORef env ledgerState =
      LocalNodeClientProtocols {
        localChainSyncClient    = LocalChainSyncClientPipelined (chainSyncClient 50 stateIORef env ledgerState),
        localTxSubmissionClient = Nothing,
        localStateQueryClient   = Nothing
      }

  -- | Add a new ledger state to the history
  pushLedgerState :: Env -> LedgerStateHistory -> SlotNo -> LedgerState -> BlockInMode CardanoMode
    -> (LedgerStateHistory, LedgerStateHistory)
    -- ^ ( The new history with the new state appended
    --   , Any exisiting ledger states that are now past the security parameter
    --      and hence can no longer be rolled back.
    --   )
  pushLedgerState env hist ix st block
    = Seq.splitAt
        (fromIntegral $ envSecurityParam env + 1)
        ((ix, st, At block) Seq.:<| hist)

  rollBackLedgerStateHist :: LedgerStateHistory -> SlotNo -> LedgerStateHistory
  rollBackLedgerStateHist hist maxInc = Seq.dropWhileL ((> maxInc) . (\(x,_,_) -> x)) hist

  -- | Defines the client side of the chain sync protocol.
  chainSyncClient :: Word32
                  -- ^ The maximum number of concurrent requests.IORef a
                  -> IORef a
                  -> Env
                  -> LedgerState
                  -> ChainSyncClientPipelined
                      (BlockInMode CardanoMode)
                      ChainPoint
                      ChainTip
                      IO ()
  chainSyncClient pipelineSize stateIORef env ledgerState0
    = ChainSyncClientPipelined $ pure $ clientIdle_RequestMoreN Origin Origin Zero initialLedgerStateHistory
    where
        initialLedgerStateHistory = Seq.singleton (0, ledgerState0, Origin) -- TODO is the initial ledger state at slot 0?

        pushLedgerState' = pushLedgerState env

        clientIdle_RequestMoreN
          :: WithOrigin BlockNo
          -> WithOrigin BlockNo
          -> Nat n
          -> LedgerStateHistory
          -> ClientPipelinedStIdle n (BlockInMode CardanoMode) ChainPoint ChainTip IO ()
        clientIdle_RequestMoreN clientTip serverTip n knownLedgerStates
          = case pipelineDecisionMax pipelineSize n clientTip serverTip  of
              Collect -> case n of
                Succ predN -> CollectResponse Nothing (clientNextN predN knownLedgerStates)
              _ -> SendMsgRequestNextPipelined (clientIdle_RequestMoreN clientTip serverTip (Succ n) knownLedgerStates)

        clientNextN
          :: Nat n
          -> LedgerStateHistory
          -> ClientStNext n (BlockInMode CardanoMode) ChainPoint ChainTip IO ()
        clientNextN n knownLedgerStates =
          ClientStNext {
              recvMsgRollForward = \blockInMode@(BlockInMode block@(Block (BlockHeader slotNo _ currBlockNo) _) _era) serverChainTip -> do
                let newLedgerState = applyBlock env (fromMaybe (error "Impossible! Missing Ledger state") . fmap (\(_,x,_) -> x) $ Seq.lookup 0 knownLedgerStates) block
                    (knownLedgerStates', committedStates) = pushLedgerState' knownLedgerStates slotNo newLedgerState blockInMode
                    newClientTip = At currBlockNo
                    newServerTip = fromChainTip serverChainTip
                forM_ committedStates $ \(_, currLedgerState, currBlockMay) -> case currBlockMay of
                    Origin -> return ()
                    At currBlock -> do
                      newState <- accumulate env currLedgerState currBlock =<< readIORef stateIORef
                      writeIORef stateIORef newState
                if newClientTip == newServerTip
                  then  clientIdle_DoneN n
                  else return (clientIdle_RequestMoreN newClientTip newServerTip n knownLedgerStates')
            , recvMsgRollBackward = \chainPoint serverChainTip -> do
                --putStrLn "Rollback"
                let newClientTip = Origin -- We don't actually keep track of blocks so we temporarily "forget" the tip.
                    newServerTip = fromChainTip serverChainTip
                    truncatedKnownLedgerStates = case chainPoint of
                        ChainPointAtGenesis -> initialLedgerStateHistory
                        ChainPoint slotNo _ -> rollBackLedgerStateHist knownLedgerStates slotNo
                return (clientIdle_RequestMoreN newClientTip newServerTip n truncatedKnownLedgerStates)
            }

        clientIdle_DoneN
          :: Nat n
          -> IO (ClientPipelinedStIdle n (BlockInMode CardanoMode) ChainPoint ChainTip IO ())
        clientIdle_DoneN n = case n of
          Succ predN -> do
            --putStrLn "Chain Sync: done! (Ignoring remaining responses)"
            return $ CollectResponse Nothing (clientNext_DoneN predN) -- Ignore remaining message responses
          Zero -> do
            --putStrLn "Chain Sync: done!"
            return $ SendMsgDone ()

        clientNext_DoneN
          :: Nat n
          -> ClientStNext n (BlockInMode CardanoMode) ChainPoint ChainTip IO ()
        clientNext_DoneN n =
          ClientStNext {
              recvMsgRollForward = \_ _ -> clientIdle_DoneN n
            , recvMsgRollBackward = \_ _ -> clientIdle_DoneN n
            }

        fromChainTip :: ChainTip -> WithOrigin BlockNo
        fromChainTip ct = case ct of
          ChainTipAtGenesis -> Origin
          ChainTip _ _ bno -> At bno

type LedgerStateHistory = Seq (SlotNo, LedgerState, WithOrigin (BlockInMode CardanoMode))
