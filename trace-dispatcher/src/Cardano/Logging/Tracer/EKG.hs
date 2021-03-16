{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Logging.Tracer.EKG where

import           Cardano.Logging.Types
import           Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Control.Tracer as T
import           Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import           Data.Text (Text, intercalate, pack)
import qualified System.Metrics as Metrics
import qualified System.Metrics.Gauge as Gauge
import qualified System.Metrics.Label as Label
import           System.Remote.Monitoring (Server, getGauge, getLabel)

ekgTracer :: (Logging a, MonadIO m) => Either Metrics.Store Server-> m (Trace m a)
ekgTracer storeOrServer = liftIO $ do
    registeredGauges <- newIORef Map.empty
    registeredLabels <- newIORef Map.empty
    pure $ T.arrow $ T.emit $ output registeredGauges registeredLabels
  where
    output registeredGauges registeredLabels (LoggingContext{..}, Right v) =
      case asMetrics v of
        [] -> pure ()
        l  -> liftIO $ mapM_ (setIt registeredGauges registeredLabels lcContext) l
    output _ _ (LoggingContext{..}, Left c) = pure ()
    setIt registeredGauges _registeredLabels namespace (IntM mbText theInt) = do
      registeredMap <- readIORef registeredGauges
      let name = case mbText of
                    Nothing -> intercalate "." namespace
                    Just t  -> intercalate "." (t : namespace)
      case Map.lookup name registeredMap of
        Just gauge -> Gauge.set gauge (fromIntegral theInt)
        Nothing -> do
          gauge <- case storeOrServer of
                      Left store   -> Metrics.createGauge name store
                      Right server -> getGauge name server
          let registeredGauges' = Map.insert name gauge registeredMap
          writeIORef registeredGauges registeredGauges'
          Gauge.set gauge (fromIntegral theInt)
    setIt _registeredGauges registeredLabels namespace (DoubleM mbText theDouble) = do
      registeredMap <- readIORef registeredLabels
      let name = case mbText of
                    Nothing -> intercalate "." namespace
                    Just t  -> intercalate "." (t : namespace)
      case Map.lookup name registeredMap of
        Just label -> Label.set label ((pack . show) theDouble)
        Nothing -> do
          label <- case storeOrServer of
                      Left store   -> Metrics.createLabel name store
                      Right server -> getLabel name server
          let registeredLabels' = Map.insert name label registeredMap
          writeIORef registeredLabels registeredLabels'
          Label.set label ((pack . show) theDouble)
