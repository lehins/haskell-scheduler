{-# OPTIONS_HADDOCK hide, not-home #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
-- |
-- Module      : Control.Scheduler.Queue
-- Copyright   : (c) Alexey Kuleshevich 2018-2019
-- License     : BSD3
-- Maintainer  : Alexey Kuleshevich <lehins@yandex.ru>
-- Stability   : experimental
-- Portability : non-portable
--
module Control.Scheduler.Queue
  (  -- * Job queue
    Job(Job_)
  , mkJob
  , Queue(..)
  , JQueue(..)
  , WorkerId(..)
  , newJQueue
  , pushJQueue
  , popJQueue
  , clearPendingJQueue
  , readResults
  , blockPopJQueue
  , unblockPopJQueue
  ) where

import Control.Concurrent.MVar
import Control.Monad (join)
import Control.Monad.IO.Unlift
import Data.Atomics (atomicModifyIORefCAS, atomicModifyIORefCAS_)
import Data.Maybe
import Data.IORef

-- | A blocking unbounded queue that keeps the jobs in FIFO order and the results IORefs
-- in reversed
data Queue m a = Queue
  { qQueue   :: ![Job m a]
  , qStack   :: ![Job m a]
  , qResults :: ![IORef (Maybe a)]
  , qBaton   :: {-# UNPACK #-}!(MVar ())
  }


-- | A unique id for the worker in the `Control.Scheduler.Scheduler` context. It will
-- always be a number from @0@ up to, but not including, the number of workers a scheduler
-- has, which in turn can always be determined with `Control.Scheduler.numWorkers` function.
--
-- @since 1.4.0
newtype WorkerId = WorkerId
  { getWorkerId :: Int
  } deriving (Show, Read, Eq, Ord, Enum, Bounded, Num, Real, Integral)


popQueue :: Queue m a -> Maybe (Job m a, Queue m a)
popQueue queue =
  case qQueue queue of
    x:xs -> Just (x, queue {qQueue = xs})
    [] ->
      case reverse (qStack queue) of
        []   -> Nothing
        y:ys -> Just (y, queue {qQueue = ys, qStack = []})
{-# INLINEABLE popQueue #-}

data Job m a
  = Job {-# UNPACK #-} !(IORef (Maybe a)) (WorkerId -> m ())
  | Job_ (WorkerId -> m ())


mkJob :: MonadIO m => ((a -> m ()) -> WorkerId -> m ()) -> m (Job m a)
mkJob action = do
  resRef <- liftIO $ newIORef Nothing
  return $ Job resRef (action (liftIO . writeIORef resRef . Just))
{-# INLINEABLE mkJob #-}

data JQueue m a =
  JQueue
    { jqQueueRef :: {-# UNPACK #-}!(IORef (Queue m a))
    , jqLock     :: {-# UNPACK #-}!(MVar ())
    }

newJQueue :: MonadIO m => m (JQueue m a)
newJQueue =
  liftIO $ do
    newLock <- newEmptyMVar
    newBaton <- newEmptyMVar
    queueRef <- newIORef (Queue [] [] [] newBaton)
    return $ JQueue queueRef newLock

-- | Pushes an item onto a queue and returns the previous count.
pushJQueue :: MonadIO m => JQueue m a -> Job m a -> m ()
pushJQueue (JQueue jQueueRef _) job =
  liftIO $ do
    newBaton <- newEmptyMVar
    join $
      atomicModifyIORefCAS jQueueRef $ \queue@Queue {qStack, qResults, qBaton} ->
        ( queue
            { qResults =
                case job of
                  Job resRef _ -> resRef : qResults
                  _ -> qResults
            , qStack = job : qStack
            , qBaton = newBaton
            }
        , putMVar qBaton ())
{-# INLINEABLE pushJQueue #-}

-- | Pops an item from the queue. The job returns the total job counts that is still left
-- in the queue
popJQueue :: MonadUnliftIO m => JQueue m a -> m (WorkerId -> m ())
popJQueue (JQueue jQueueRef lock) = liftIO inner
  where
    inner = do
      readMVar lock
      join $
        atomicModifyIORefCAS jQueueRef $ \queue@Queue {qBaton} ->
          case popQueue queue of
            Nothing -> (queue, readMVar qBaton >> inner)
            Just (job, newQueue) ->
              ( newQueue
              , case job of
                  Job _ action -> return action
                  Job_ action_ -> return action_)
{-# INLINEABLE popJQueue #-}

unblockPopJQueue :: MonadIO m => JQueue m a -> m ()
unblockPopJQueue (JQueue _ lock) = liftIO $ putMVar lock ()
{-# INLINEABLE unblockPopJQueue #-}

blockPopJQueue :: MonadIO m => JQueue m a -> m ()
blockPopJQueue (JQueue _ lock) = liftIO $ takeMVar lock
{-# INLINEABLE blockPopJQueue #-}

-- | Clears any jobs that haven't been started yet. Returns the number of jobs that are
-- still in progress and have not been yet been completed.
clearPendingJQueue :: MonadIO m => JQueue m a -> m ()
clearPendingJQueue (JQueue queueRef _) =
  liftIO $ atomicModifyIORefCAS_ queueRef $ \queue -> (queue {qQueue = [], qStack = []})
{-# INLINEABLE clearPendingJQueue #-}


-- | Extracts all results available up to now, the uncomputed ones are discarded. This
-- also has an affect of resetting the total job count to zero.
readResults :: MonadIO m => JQueue m a -> m [a]
readResults (JQueue jQueueRef _) =
  liftIO $ do
    results <-
      atomicModifyIORefCAS jQueueRef $ \queue ->
        (queue {qQueue = [], qStack = [], qResults = []}, qResults queue)
    catMaybes <$> mapM readIORef results
{-# INLINEABLE readResults #-}


