module Data.Conduit.INotify where

import Conduit (ConduitT, MonadIO, bracketP, lift, liftIO, (.|))
import qualified Conduit as C (await, awaitForever, mapInput, sourceHandle, yield)
import Control.Concurrent.STM (TVar, newTVar, newTVarIO, readTVarIO, writeTVar)
import Control.Concurrent.STM.TMQueue (TMQueue, closeTMQueue, newTMQueue, writeTMQueue)
import Control.Exception (tryJust)
import Control.Monad.Except (guard)
import Control.Monad.STM (STM, atomically)
import Control.Monad.Trans.Resource (MonadResource)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (hGetSome)
import qualified Data.ByteString.Lazy.Internal as BS (defaultChunkSize)
import qualified Data.Conduit.List as C (catMaybes, map, mapMaybe)
import Data.Conduit.TQueue (sourceTMQueue)
import Data.Foldable (traverse_)
import System.FilePath.ByteString (encodeFilePath)
import qualified System.INotify as INotify (Event (DeletedSelf, Modified), EventVariety (DeleteSelf, Modify), INotify, WatchDescriptor, addWatch, initINotify, killINotify, removeWatch)
import qualified System.IO as IO (Handle, IOMode (ReadMode), SeekMode (AbsoluteSeek), hClose, hSeek, hTell, openFile)
import qualified System.IO.Error as IO (isEOFError)

-- | Run 'ConduitT' with 'INotify'
withINotify :: MonadResource m => (INotify.INotify -> ConduitT a b m r) -> ConduitT a b m r
withINotify = bracketP INotify.initINotify INotify.killINotify

-- | Watch INotify events for given file
-- Does not support file rotation.
-- Once the watched file is removed, it will not emit any additional events and needs to be terminated via handle.
inotifyEventsSource ::
  (MonadResource m, Monad m) =>
  -- | events to watch for
  [INotify.EventVariety] ->
  -- | path to file to be watched
  FilePath ->
  -- | returns (source, handle to terminate the watch)
  STM (ConduitT () INotify.Event m (), STM ())
inotifyEventsSource events fp = do
  q <- newTMQueue
  return (withINotify (\i -> bracketP (initialize i q) cleanup (inside q)), closeTMQueue q)
  where
    initialize i q = INotify.addWatch i events (encodeFilePath fp) (atomically . writeTMQueue q)
    cleanup = INotify.removeWatch
    inside q _ = sourceTMQueue q

-- | Stream contents of a 'IO.Handle' as binary data.
-- Will yield Nothing after EOF is reached
sourceHandleEof :: MonadIO m => IO.Handle -> ConduitT () (Maybe ByteString) m ()
sourceHandleEof h = C.sourceHandle h .| C.map Just <> C.yield Nothing

-- | Stream contents of a file as binary data.
-- Once EOF is reached it waits for file modifications and streams data as they are appended to the file.
-- Once the watch is terminated, it will read the file until EOF is reached.
--
-- Source emits 'Nothing' when EOF is reached. For version emitting just data see 'sourceFileFollowModify\''
-- Does not support file rotations. For version supporing rotations see 'sourceFileFollowModifyRotateWithSeek'
sourceFileFollowModify ::
  (MonadResource m, MonadIO m) =>
  -- patch to file to be followed
  FilePath ->
  -- returns (source of binary data from file, handle to terminate the follow)
  STM (ConduitT () (Maybe ByteString) m (), STM ())
sourceFileFollowModify fp =
  do
    (eventsSource, closeWatch) <- inotifyEventsSource [INotify.Modify] fp
    return (bracketP (IO.openFile fp IO.ReadMode) IO.hClose (inside eventsSource), closeWatch)
  where
    inside :: MonadIO m => ConduitT () INotify.Event m () -> IO.Handle -> ConduitT () (Maybe ByteString) m ()
    inside eventsSource h =
      sourceHandleEof h -- read file before any event appears
        <> (eventsSource .| C.awaitForever (\e -> C.mapInput (const ()) (const $ Just e) $ sourceHandleEof h)) -- reread from handle after each modify event
        <> sourceHandleEof h -- read to the end of the file after the watch ends

-- | Version of 'sourceFileFollowModify' not notifying about EOF
sourceFileFollowModify' :: (MonadResource m, MonadIO m) => FilePath -> STM (ConduitT () ByteString m (), STM ())
sourceFileFollowModify' fp = do
  (source, close) <- sourceFileFollowModify fp
  return (source .| C.catMaybes, close)

-- | Like 'bracketP', but resource can be released within 'in-between' computation.
-- Resource is recreated after release if needed
replacableBracketP ::
  MonadResource m =>
  -- acquire resource computation
  IO a ->
  -- release resource computation
  (a -> IO ()) ->
  -- computation to run in-between.
  -- first: acquires the resource if not available, otherwise just gets it
  -- second: releases the resource
  ((m a, m ()) -> ConduitT i o m ()) ->
  ConduitT i o m ()
replacableBracketP initialize cleanup inside =
  let getOrInitialize var = liftIO $ do
        maybeA <- readTVarIO var
        case maybeA of
          Just a -> return a
          Nothing -> do
            a <- initialize
            atomically $ writeTVar var (Just a)
            return a
      cleanupAndUnset var = liftIO $ do
        maybeA <- readTVarIO var
        traverse_ cleanup maybeA
        atomically $ writeTVar var Nothing
   in bracketP
        (initialize >>= newTVarIO . Just)
        cleanupAndUnset
        (\var -> inside (getOrInitialize var, cleanupAndUnset var))

-- | Watch INotify events for given file.
-- Interprets file removal as file rotation and tries to recreate the watch again.
inotifyEventsSourceRotate :: MonadResource m => [INotify.EventVariety] -> FilePath -> STM (ConduitT () INotify.Event m (), STM ())
inotifyEventsSourceRotate events fp = do
  q <- newTMQueue
  let c = sourceTMQueue q .| withINotify (\i -> replacableBracketP (initialize i q) cleanup inside)
  return (c, closeTMQueue q)
  where
    -- WatchDescriptior is stored within TVar because it destroys itself when the watched file is deleted
    initialize :: INotify.INotify -> TMQueue INotify.Event -> IO (TVar (Maybe INotify.WatchDescriptor))
    initialize i q = do
      w <- INotify.addWatch i (INotify.DeleteSelf : events) (encodeFilePath fp) (atomically . writeTMQueue q)
      newTVarIO $ Just w

    cleanup :: TVar (Maybe INotify.WatchDescriptor) -> IO ()
    cleanup var = readTVarIO var >>= traverse_ INotify.removeWatch

    inside :: MonadIO m => (m (TVar (Maybe INotify.WatchDescriptor)), m ()) -> ConduitT INotify.Event INotify.Event m ()
    inside (getOrInit, unset) = do
      var <- lift getOrInit
      event <- C.await

      case event of
        Just e@INotify.DeletedSelf {} -> do
          C.yield e
          liftIO $ atomically $ writeTVar var Nothing -- WatchDescriptor is deleted implicitly
          lift unset
          inside (getOrInit, unset)
        Just other -> do
          C.yield other
          inside (getOrInit, unset)
        Nothing ->
          return ()

data FollowFileEvent = Replaced | Modified deriving (Eq, Show)

-- | Stream contents of a file as binary data.
-- Once EOF is reached it waits for file modifications and streams data as they are appended to the file.
-- Once the watch is terminated, it will read the file until EOF is reached.
--
-- Interprets file removal as file rotation and tries to recreate the watch and continue to follow the file from last position (expects just rotation that resembles append to file).
-- Source emits 'Nothing' when EOF is reached. For version emitting just data see 'sourceFileFollowModifyRotateWithSeek\''
sourceFileFollowModifyRotateWithSeek :: (MonadResource m, MonadIO m) => FilePath -> STM (ConduitT () (Maybe ByteString) m (), STM ())
sourceFileFollowModifyRotateWithSeek fp = do
  (eventsSource, closeWatch) <- inotifyEventsSourceRotate [INotify.Modify] fp
  positionVar <- newTVar Nothing
  return (eventsSource .| C.mapMaybe handleINotifyEvent .| replacableBracketP (initialize positionVar) cleanup (inside positionVar), closeWatch)
  where
    handleINotifyEvent INotify.Modified {} = Just Modified
    handleINotifyEvent INotify.DeletedSelf {} = Just Replaced
    handleINotifyEvent _ = Nothing

    initialize :: TVar (Maybe Integer) -> IO IO.Handle
    initialize positionVar = do
      newHandle <- liftIO $ IO.openFile fp IO.ReadMode
      maybePosition <- readTVarIO positionVar
      traverse_ (IO.hSeek newHandle IO.AbsoluteSeek) maybePosition -- seek to original position
      return newHandle

    cleanup :: IO.Handle -> IO ()
    cleanup = IO.hClose

    inside :: MonadIO m => TVar (Maybe Integer) -> (m IO.Handle, m ()) -> ConduitT FollowFileEvent (Maybe ByteString) m ()
    inside positionVar (getOrInit, unset) = do
      handle <- lift getOrInit
      line <- liftIO $ tryJust (guard . IO.isEOFError) $ BS.hGetSome handle BS.defaultChunkSize

      case line of
        Right l -> do
          C.yield $ Just l
          inside positionVar (getOrInit, unset)
        Left _ -> do
          -- eof reached
          C.yield Nothing
          event <- C.await
          case event of
            Just Replaced -> do
              -- store current position
              pos <- liftIO $ IO.hTell handle
              liftIO $ atomically $ writeTVar positionVar $ Just pos
              -- remove current handle
              lift unset
              inside positionVar (getOrInit, unset)
            Just Modified ->
              inside positionVar (getOrInit, unset)
            Nothing ->
              -- read the file until EOF after the watch is terminated
              C.mapInput (const ()) (const event) (sourceHandleEof handle)

-- | Version of 'sourceFileFollowModifyRotateWithSeek' not notifying about EOF
sourceFileFollowModifyRotateWithSeek' :: (MonadResource m, MonadIO m) => FilePath -> STM (ConduitT () ByteString m (), STM ())
sourceFileFollowModifyRotateWithSeek' fp = do
  (source, close) <- sourceFileFollowModifyRotateWithSeek fp
  return (source .| C.catMaybes, close)
