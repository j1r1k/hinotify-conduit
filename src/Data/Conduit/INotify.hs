{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TupleSections #-}

module Data.Conduit.INotify where

import Conduit (ConduitT, MonadIO, bracketP, lift, liftIO, (.|))
import qualified Conduit as C (await, awaitForever, mapInput, sourceHandle, yield)
import Control.Concurrent.STM (TVar, modifyTVar, newTVar, newTVarIO, readTVarIO, writeTVar)
import Control.Concurrent.STM.TMQueue (TMQueue, closeTMQueue, newTMQueue, writeTMQueue)
import Control.Monad.STM (STM, atomically)
import Control.Monad.Trans.Resource (MonadResource)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (hGetSome, null)
import qualified Data.ByteString.Lazy.Internal as BS (defaultChunkSize)
import qualified Data.Conduit.List as C (catMaybes, map, mapMaybe)
import Data.Conduit.TQueue (sourceTMQueue)
import Data.Foldable (traverse_)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NonEmpty (toList)
import Data.Map (Map)
import qualified Data.Map as Map (delete, fromList, insert, notMember)
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.FilePath.ByteString (encodeFilePath)
import System.FilePath.Posix.ByteString (decodeFilePath)
import System.INotify (filePath)
import qualified System.INotify as INotify (Event (Ignored, Modified, MovedIn), EventVariety (DeleteSelf, Modify, MoveIn), INotify, WatchDescriptor, addWatch, removeWatch)
import qualified System.IO as IO (Handle, IOMode (ReadMode), SeekMode (AbsoluteSeek), hClose, hSeek, hTell, openFile)

-- | Watch INotify events for given file
-- Does not support file rotation.
-- Once the watched file is removed, it will not emit any additional events and needs to be terminated via handle.
inotifyEventsSource ::
  (MonadResource m, Monad m) =>
  -- | INotify
  INotify.INotify ->
  -- | events to watch for
  NonEmpty INotify.EventVariety ->
  -- | path to file to be watched
  FilePath ->
  -- | returns (source, handle to terminate the watch)
  STM (ConduitT () INotify.Event m (), STM ())
inotifyEventsSource i events fp = do
  q <- newTMQueue
  return (bracketP (initialize q) cleanup (inside q), closeTMQueue q)
  where
    initialize q = INotify.addWatch i (NonEmpty.toList events) (encodeFilePath fp) (atomically . writeTMQueue q)
    cleanup = INotify.removeWatch
    inside q _ = sourceTMQueue q

-- | Stream contents of a 'IO.Handle' as binary data and yield Nothing after EOF is reached
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
  -- | INotify
  INotify.INotify ->
  -- | path to file to be followed
  FilePath ->
  -- | returns (source of binary data from file, handle to terminate the follow)
  STM (ConduitT () (Maybe ByteString) m (), STM ())
sourceFileFollowModify i fp =
  do
    (eventsSource, closeWatch) <- inotifyEventsSource i (INotify.Modify :| [] {- TODO singleton -}) fp
    return (bracketP (IO.openFile fp IO.ReadMode) IO.hClose (inside eventsSource), closeWatch)
  where
    inside :: MonadIO m => ConduitT () INotify.Event m () -> IO.Handle -> ConduitT () (Maybe ByteString) m ()
    inside eventsSource h =
      sourceHandleEof h -- read file before any event appears
        <> (eventsSource .| C.awaitForever (\e -> C.mapInput (const ()) (const $ Just e) $ sourceHandleEof h)) -- reread from handle after each modify event
        <> sourceHandleEof h -- read to the end of the file after the watch ends

-- | Version of 'sourceFileFollowModify' not notifying about EOF
sourceFileFollowModify' :: (MonadResource m, MonadIO m) => INotify.INotify -> FilePath -> STM (ConduitT () ByteString m (), STM ())
sourceFileFollowModify' i fp = do
  (source, close) <- sourceFileFollowModify i fp
  return (source .| C.catMaybes, close)

-- | Like 'bracketP', but resource can be released within 'in-between' computation.
-- Resource is recreated after release if needed
replacableBracketP ::
  MonadResource m =>
  -- | acquire resource computation
  IO a ->
  -- | release resource computation
  (a -> IO ()) ->
  -- | computation to run in-between.
  -- | first: acquires the resource if not available, otherwise just gets it
  -- | second: releases the resource
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
inotifyEventsSourceRotate :: MonadResource m => INotify.INotify -> NonEmpty INotify.EventVariety -> FilePath -> STM (ConduitT () INotify.Event m (), STM ())
inotifyEventsSourceRotate i events fp = do
  q <- newTMQueue
  let c = sourceTMQueue q .| replacableBracketP (initialize q) cleanup inside
  return (c, closeTMQueue q)
  where
    -- WatchDescriptior is stored within TVar because it destroys itself when the watched file is deleted
    initialize :: TMQueue INotify.Event -> IO (TVar (Maybe INotify.WatchDescriptor))
    initialize q = do
      w <- INotify.addWatch i (INotify.DeleteSelf : NonEmpty.toList events) (encodeFilePath fp) (atomically . writeTMQueue q)
      newTVarIO $ Just w

    cleanup :: TVar (Maybe INotify.WatchDescriptor) -> IO ()
    cleanup var = readTVarIO var >>= traverse_ INotify.removeWatch

    inside :: MonadIO m => (m (TVar (Maybe INotify.WatchDescriptor)), m ()) -> ConduitT INotify.Event INotify.Event m ()
    inside (getOrInit, unset) = do
      var <- lift getOrInit
      event <- C.await

      case event of
        Just e@INotify.Ignored -> do
          C.yield e
          liftIO $ atomically $ writeTVar var Nothing -- WatchDescriptor is deleted implicitly
          lift unset
          inside (getOrInit, unset)
        Just other -> do
          C.yield other
          inside (getOrInit, unset)
        Nothing ->
          return ()

inotifyEventsSourceRotateMultiple :: MonadResource m => INotify.INotify -> [(NonEmpty INotify.EventVariety, FilePath)] -> STM (ConduitT () (INotify.Event, FilePath) m (), STM ())
inotifyEventsSourceRotateMultiple i eventsToFp = do
  q <- newTMQueue
  let c = sourceTMQueue q .| replacableBracketP (initialize q) cleanup (inside q)
  return (c, closeTMQueue q)
  where
    initializeSingle :: TMQueue (INotify.Event, FilePath) -> NonEmpty INotify.EventVariety -> FilePath -> IO INotify.WatchDescriptor
    initializeSingle q events fp =
      INotify.addWatch i (NonEmpty.toList events) (encodeFilePath fp) (atomically . writeTMQueue q . (,fp))

    initialize :: TMQueue (INotify.Event, FilePath) -> IO (TVar (Map FilePath INotify.WatchDescriptor))
    initialize q = do
      ws <- traverse (\(events, fp) -> (fp,) <$> initializeSingle q events fp) eventsToFp
      newTVarIO $ Map.fromList ws

    cleanup :: TVar (Map FilePath INotify.WatchDescriptor) -> IO ()
    cleanup var = readTVarIO var >>= traverse_ INotify.removeWatch

    inside :: MonadIO m => TMQueue (INotify.Event, FilePath) -> (m (TVar (Map FilePath INotify.WatchDescriptor)), m ()) -> ConduitT (INotify.Event, FilePath) (INotify.Event, FilePath) m ()
    inside q (getOrInit, unset) = do
      var <- lift getOrInit
      ws <- liftIO $ readTVarIO var
      -- initialize all WatchDescriptors that might be missing
      liftIO $ traverse_ (\(events, fp) -> if Map.notMember fp ws then initializeSingle q events fp >>= atomically . modifyTVar var . Map.insert fp else pure ()) eventsToFp
      event <- C.await

      case event of
        Just e@(INotify.Ignored, fp) -> do
          C.yield e
          liftIO $ atomically $ modifyTVar var (Map.delete fp) -- WatchDescriptor is deleted implicitly
          inside q (getOrInit, unset)
        Just other -> do
          C.yield other
          inside q (getOrInit, unset)
        Nothing ->
          return ()

data FollowFileEvent = Replaced | Modified deriving (Eq, Show)

-- | Stream contents of a file as binary data.
-- Once EOF is reached it waits for file modifications and streams data as they are appended to the file.
-- Once the watch is terminated, it will read the file until EOF is reached.
--
-- Interprets file removal as file rotation and tries to recreate the watch and continue to follow the file from last position (expects just rotation that resembles append to file).
-- Source emits 'Nothing' when EOF is reached. For version emitting just data see 'sourceFileFollowModifyRotateWithSeek\''
--
-- Since the handle prevents the file from deleting, it is watching a parent directory for 'INotify.MoveIn' events and interprets them as rotations
sourceFileFollowModifyRotateWithSeek ::
  (MonadResource m, MonadIO m) =>
  -- | INotify
  INotify.INotify ->
  -- | path to parent directory
  FilePath ->
  -- | file name relative to parent directory
  FilePath ->
  -- | (source, handle to terminate the watch)
  STM (ConduitT () (Maybe ByteString) m (), STM ())
sourceFileFollowModifyRotateWithSeek i parent fp = do
  (eventsSource, closeWatch) <- inotifyEventsSourceRotateMultiple i [(INotify.MoveIn :| [], parent), (INotify.DeleteSelf :| [INotify.Modify], parent </> fp)]
  positionVar <- newTVar Nothing
  return (eventsSource .| C.mapMaybe handleINotifyEvent .| replacableBracketP (initialize positionVar) cleanup (inside positionVar), closeWatch)
  where
    handleINotifyEvent (INotify.Modified {}, fp') = if fp' == parent </> fp then Just Modified else Nothing
    handleINotifyEvent (INotify.MovedIn {filePath = fp'}, parent') = if parent == parent' && fp == decodeFilePath fp' then Just Replaced else Nothing
    handleINotifyEvent _ = Nothing

    initialize :: TVar (Maybe Integer) -> IO IO.Handle
    initialize positionVar = do
      newHandle <- IO.openFile (parent </> fp) IO.ReadMode
      maybePosition <- readTVarIO positionVar
      traverse_ (IO.hSeek newHandle IO.AbsoluteSeek) maybePosition -- seek to original position
      return newHandle

    cleanup :: IO.Handle -> IO ()
    cleanup = IO.hClose

    inside :: MonadIO m => TVar (Maybe Integer) -> (m IO.Handle, m ()) -> ConduitT FollowFileEvent (Maybe ByteString) m ()
    inside positionVar (getOrInit, unset) = do
      handle <- lift getOrInit
      line <- liftIO $ BS.hGetSome handle BS.defaultChunkSize

      if BS.null line
        then do
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
        else do
          C.yield $ Just line
          inside positionVar (getOrInit, unset)

-- | Version of 'sourceFileFollowModifyRotateWithSeek' not notifying about EOF
sourceFileFollowModifyRotateWithSeek' ::
  (MonadResource m, MonadIO m) =>
  -- | INotify
  INotify.INotify ->
  -- | path to parent directory
  FilePath ->
  -- | file name relative to parent directory
  FilePath ->
  -- | (source, handle to terminate the watch)
  STM (ConduitT () ByteString m (), STM ())
sourceFileFollowModifyRotateWithSeek' i parent fp = do
  (source, close) <- sourceFileFollowModifyRotateWithSeek i parent fp
  return (source .| C.catMaybes, close)

-- | Version of 'sourceFileFollowModifyRotateWithSeek' that determines parent directory
sourceFileFollowModifyRotateWithSeekIO ::
  (MonadResource m, MonadIO m) =>
  -- | INotify
  INotify.INotify ->
  -- | file name
  FilePath ->
  -- | (source, handle to terminate the watch)
  IO (ConduitT () (Maybe ByteString) m (), STM ())
sourceFileFollowModifyRotateWithSeekIO i fp = do
  absoluteFp <- canonicalizePath fp
  atomically $ sourceFileFollowModifyRotateWithSeek i (takeDirectory absoluteFp) (takeFileName absoluteFp)

-- | Version of 'sourceFileFollowModifyRotateWithSeek\'' that determines parent directory
sourceFileFollowModifyRotateWithSeekIO' ::
  (MonadResource m, MonadIO m) =>
  -- | INotify
  INotify.INotify ->
  -- | file name
  FilePath ->
  -- | (source, handle to terminate the watch)
  IO (ConduitT () ByteString m (), STM ())
sourceFileFollowModifyRotateWithSeekIO' i fp = do
  (source, close) <- sourceFileFollowModifyRotateWithSeekIO i fp
  return (source .| C.catMaybes, close)
