{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Module      : Control.Scheduler
-- Copyright   : (c) Alexey Kuleshevich 2018-2019
-- License     : BSD3
-- Maintainer  : Alexey Kuleshevich <lehins@yandex.ru>
-- Stability   : experimental
-- Portability : non-portable
--
module Control.Scheduler
  ( -- * Scheduler and strategies
    Comp(..)
  , Scheduler(..)
  -- * Initialize Scheduler
  , withScheduler
  , withScheduler_
  -- * Useful functions
  , replicateConcurrently
  , replicateConcurrently_
  , traverseConcurrently
  , traverseConcurrently_
  , traverse_
  -- * Exceptions
  -- $exceptions
  ) where

import Control.Concurrent
import Control.Exception
import Control.Scheduler.Computation
import Control.Scheduler.Queue
import Control.Monad
import Control.Monad.IO.Unlift
import Data.Atomics (atomicModifyIORefCAS, atomicModifyIORefCAS_)
import qualified Data.Foldable as F (foldl', traverse_)
import Data.IORef
import Data.Traversable

data Jobs m a = Jobs
  { jobsNumWorkers :: {-# UNPACK #-} !Int
  , jobsQueue      :: !(JQueue m a)
  , jobsCountRef   :: !(IORef Int)
  }

-- | Main type for scheduling work. See `withScheduler` or `withScheduler_` for the only ways to get
-- access to such data type.
--
-- @since 1.0.0
data Scheduler m a = Scheduler
  { numWorkers   :: {-# UNPACK #-} !Int
  -- ^ Get the number of workers.
  , scheduleWork :: m a -> m ()
  -- ^ Schedule an action to be picked up and computed by a worker from a pool.
  }

-- | This is generally a faster way to traverse while ignoring the result rather than using `mapM_`.
--
-- @since 1.0.0
traverse_ :: (Applicative f, Foldable t) => (a -> f ()) -> t a -> f ()
traverse_ f = F.foldl' (\c a -> c *> f a) (pure ())


-- | Map an action over each element of the `Traversable` @t@ acccording to the supplied computation
-- strategy.
--
-- @since 1.0.0
traverseConcurrently :: (MonadUnliftIO m, Traversable t) => Comp -> (a -> m b) -> t a -> m (t b)
traverseConcurrently comp f xs = do
  ys <- withScheduler comp $ \s -> traverse_ (scheduleWork s . f) xs
  pure $ transList ys xs

transList :: Traversable t => [a] -> t b -> t a
transList xs' = snd . mapAccumL withR xs'
  where
    withR (x:xs) _ = (xs, x)
    withR _      _ = error "Impossible<traverseConcurrently> - Mismatched sizes"

-- | Just like `traverseConcurrently`, but restricted to `Foldable` and discards the results of
-- computation.
--
-- @since 1.0.0
traverseConcurrently_ :: (MonadUnliftIO m, Foldable t) => Comp -> (a -> m b) -> t a -> m ()
traverseConcurrently_ comp f xs =
  withScheduler_ comp $ \s -> scheduleWork s $ F.traverse_ (scheduleWork s . void . f) xs

-- | Replicate an action @n@ times and schedule them acccording to the supplied computation
-- strategy.
--
-- @since 1.1.0
replicateConcurrently :: MonadUnliftIO m => Comp -> Int -> m a -> m [a]
replicateConcurrently comp n f =
  withScheduler comp $ \s -> replicateM_ n $ scheduleWork s f

-- | Just like `replicateConcurrently`, but discards the results of computation.
--
-- @since 1.1.0
replicateConcurrently_ :: MonadUnliftIO m => Comp -> Int -> m a -> m ()
replicateConcurrently_ comp n f =
  withScheduler_ comp $ \s -> scheduleWork s $ replicateM_ n (scheduleWork s $ void f)


scheduleJobs :: MonadIO m => Jobs m a -> m a -> m ()
scheduleJobs = scheduleJobsWith mkJob

-- | Similarly to `scheduleWork`, but ignores the result of computation, thus having less overhead.
--
-- @since 1.0.0
scheduleJobs_ :: MonadIO m => Jobs m a -> m b -> m ()
scheduleJobs_ = scheduleJobsWith (return . Job_ . void)

scheduleJobsWith :: MonadIO m => (m b -> m (Job m a)) -> Jobs m a -> m b -> m ()
scheduleJobsWith mkJob' Jobs {jobsQueue, jobsCountRef, jobsNumWorkers} action = do
  liftIO $ atomicModifyIORefCAS_ jobsCountRef (+ 1)
  job <-
    mkJob' $ do
      res <- action
      res `seq` dropCounterOnZero jobsCountRef $ retireWorkersN jobsQueue jobsNumWorkers
      return res
  pushJQueue jobsQueue job

-- | Helper function to place required number of @Retire@ instructions on the job queue.
retireWorkersN :: MonadIO m => JQueue m a -> Int -> m ()
retireWorkersN jobsQueue n = traverse_ (pushJQueue jobsQueue) $ replicate n Retire

-- | Decrease a counter by one and perform an action when it drops down to zero.
dropCounterOnZero :: MonadIO m => IORef Int -> m () -> m ()
dropCounterOnZero counterRef onZero = do
  jc <-
    liftIO $
    atomicModifyIORefCAS
      counterRef
      (\ !i' ->
         let !i = i' - 1
          in (i, i))
  when (jc == 0) onZero


-- | Runs the worker until the job queue is exhausted, at which point it will exhecute the final task
-- of retirement and return
runWorker :: MonadIO m =>
             JQueue m a
          -> m () -- ^ Action to run upon retirement
          -> m ()
runWorker jQueue onRetire = go
  where
    go =
      popJQueue jQueue >>= \case
        Just job -> job >> go
        Nothing -> onRetire


-- | Initialize a scheduler and submit jobs that will be computed sequentially or in parallelel,
-- which is determined by the `Comp`utation strategy.
--
-- Here are some cool properties about the `withScheduler`:
--
-- * This function will block until all of the submitted jobs have finished or at least one of them
--   resulted in an exception, which will be re-thrown at the callsite.
--
-- * It is totally fine for nested jobs to submit more jobs for the same or other scheduler
--
-- * It is ok to initialize multiple schedulers at the same time, although that will likely result
--   in suboptimal performance, unless workers are pinned to different capabilities.
--
-- * __Warning__ It is very dangerous to schedule jobs that do blocking `IO`, since it can lead to a
--   deadlock very quickly, if you are not careful. Consider this example. First execution works fine,
--   since there are two scheduled workers, and one can unblock the other, but the second scenario
--   immediately results in a deadlock.
--
-- >>> withScheduler (ParOn [1,2]) $ \s -> newEmptyMVar >>= (\ mv -> scheduleWork s (readMVar mv) >> scheduleWork s (putMVar mv ()))
-- [(),()]
-- >>> import System.Timeout
-- >>> timeout 1000000 $ withScheduler (ParOn [1]) $ \s -> newEmptyMVar >>= (\ mv -> scheduleWork s (readMVar mv) >> scheduleWork s (putMVar mv ()))
-- Nothing
--
-- __Important__: In order to get work done truly in parallel, program needs to be compiled with
-- @-threaded@ GHC flag and executed with @+RTS -N -RTS@ to use all available cores.
--
-- @since 1.0.0
withScheduler ::
     MonadUnliftIO m
  => Comp -- ^ Computation strategy
  -> (Scheduler m a -> m b)
     -- ^ Action that will be scheduling all the work.
  -> m [a]
withScheduler comp = withSchedulerInternal comp scheduleJobs flushResults


-- | Same as `withScheduler`, but discards results of submitted jobs.
--
-- @since 1.0.0
withScheduler_ ::
     MonadUnliftIO m
  => Comp -- ^ Computation strategy
  -> (Scheduler m a -> m b)
     -- ^ Action that will be scheduling all the work.
  -> m ()
withScheduler_ comp = withSchedulerInternal comp scheduleJobs_ (const (pure ()))


withSchedulerInternal ::
     MonadUnliftIO m
  => Comp -- ^ Computation strategy
  -> (Jobs m a -> m a -> m ()) -- ^ How to schedule work
  -> (JQueue m a -> m c) -- ^ How to collect results
  -> (Scheduler m a -> m b)
     -- ^ Action that will be scheduling all the work.
  -> m c
withSchedulerInternal comp submitWork collect onScheduler = do
  jobsNumWorkers <-
    case comp of
      Seq      -> return 1
      Par      -> liftIO getNumCapabilities
      ParOn ws -> return $ length ws
      ParN 0   -> liftIO getNumCapabilities
      ParN n   -> return $ fromIntegral n
  sWorkersCounterRef <- liftIO $ newIORef jobsNumWorkers
  jobsQueue <- newJQueue
  jobsCountRef <- liftIO $ newIORef 0
  workDoneMVar <- liftIO newEmptyMVar
  let jobs = Jobs {..}
      scheduler = Scheduler {numWorkers = jobsNumWorkers, scheduleWork = submitWork jobs}
      onRetire = dropCounterOnZero sWorkersCounterRef $ liftIO (putMVar workDoneMVar Nothing)
  -- / Wait for the initial jobs to get scheduled before spawining off the workers, otherwise it
  -- would be trickier to identify the beginning and the end of a job pool.
  _ <- onScheduler scheduler
  -- / Ensure at least something gets scheduled, so retirement can be triggered
  jc <- liftIO $ readIORef jobsCountRef
  when (jc == 0) $ scheduleJobs_ jobs (pure ())
  let spawnWorkersWith fork ws =
        withRunInIO $ \run ->
          forM ws $ \w ->
            fork w $ \unmask ->
              catch
                (unmask $ run $ runWorker jobsQueue onRetire)
                (run . handleWorkerException jobsQueue workDoneMVar jobsNumWorkers)
      spawnWorkers =
        case comp of
          Seq -> return []
            -- \ no need to fork threads for a sequential computation
          Par -> spawnWorkersWith forkOnWithUnmask [1 .. jobsNumWorkers]
          ParOn ws -> spawnWorkersWith forkOnWithUnmask ws
          ParN _ -> spawnWorkersWith (\_ -> forkIOWithUnmask) [1 .. jobsNumWorkers]
      doWork = do
        when (comp == Seq) $ runWorker jobsQueue onRetire
        mExc <- liftIO $ readMVar workDoneMVar
        -- \ wait for all worker to finish. If any one of them had a problem this MVar will
        -- contain an exception
        case mExc of
          Nothing                    -> collect jobsQueue
          -- \ Now we are sure all workers have done their job we can safely read all of the
          -- IORefs with results
          Just (WorkerException exc) -> liftIO $ throwIO exc
          -- \ Here we need to unwrap the legit worker exception and rethrow it, so the main thread
          -- will think like it's his own
  safeBracketOnError
    spawnWorkers
    (liftIO . traverse_ (`throwTo` SomeAsyncException WorkerTerminateException))
    (const doWork)


-- | Specialized exception handler for the work scheduler.
handleWorkerException ::
  MonadIO m => JQueue m a -> MVar (Maybe WorkerException) -> Int -> SomeException -> m ()
handleWorkerException jQueue workDoneMVar nWorkers exc =
  case asyncExceptionFromException exc of
    Just WorkerTerminateException -> return ()
      -- \ some co-worker died, we can just move on with our death.
    _ -> do
      _ <- liftIO $ tryPutMVar workDoneMVar $ Just $ WorkerException exc
      -- \ Main thread must know how we died
      -- / Do the co-worker cleanup
      retireWorkersN jQueue (nWorkers - 1)


-- | This exception should normally be not seen in the wild. The only one that could possibly pop up
-- is the `WorkerAsyncException`.
newtype WorkerException =
  WorkerException SomeException
  -- ^ One of workers experienced an exception, main thread will receive the same `SomeException`.
  deriving (Show)

instance Exception WorkerException where
  displayException workerExc =
    case workerExc of
      WorkerException exc ->
        "A worker handled a job that ended with exception: " ++ displayException exc

data WorkerTerminateException =
  WorkerTerminateException
  -- ^ When a brother worker dies of some exception, all the other ones will be terminated
  -- asynchronously with this one.
  deriving (Show)


instance Exception WorkerTerminateException where
  displayException WorkerTerminateException = "A worker was terminated by the scheduler"


-- Copy from unliftio:
safeBracketOnError :: MonadUnliftIO m => m a -> (a -> m b) -> (a -> m c) -> m c
safeBracketOnError before after thing = withRunInIO $ \run -> mask $ \restore -> do
  x <- run before
  res1 <- try $ restore $ run $ thing x
  case res1 of
    Left (e1 :: SomeException) -> do
      _ :: Either SomeException b <-
        try $ uninterruptibleMask_ $ run $ after x
      throwIO e1
    Right y -> return y

{- $exceptions

If any one of the workers dies with an exception, even if that exceptions is asynchronous, it will be
re-thrown in the scheduling thread.

>>> let didAWorkerDie = handleJust asyncExceptionFromException (return . (== ThreadKilled)) . fmap or
>>> :t didAWorkerDie
didAWorkerDie :: Foldable t => IO (t Bool) -> IO Bool
>>> didAWorkerDie $ withScheduler Par $ \ s -> scheduleWork s $ pure False
False
>>> didAWorkerDie $ withScheduler Par $ \ s -> scheduleWork s $ myThreadId >>= killThread >> pure False
True
>>> withScheduler Par $ \ s -> scheduleWork s $ myThreadId >>= killThread >> pure False
*** Exception: thread killed

-}
