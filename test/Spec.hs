{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}

import Conduit (ConduitT, ResourceT, ZipSink (ZipSink), getZipSink, runConduit, runResourceT, (.|))
import qualified Conduit as C
import Control.Concurrent.Async (Async, async)
import qualified Control.Concurrent.Async as Async (wait)
import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, readTQueue)
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.Conduit.INotify (inotifyEventsSource, inotifyEventsSourceRotate, sourceFileFollowModify, sourceFileFollowModifyRotateWithSeekIO)
import qualified Data.Conduit.List as C (mapMaybe)
import Data.Conduit.TQueue (sinkTQueue)
import Data.Functor (void)
import Data.List.NonEmpty (NonEmpty ((:|)))
import GHC.Conc (threadDelay)
import GHC.IO.Exception (IOErrorType (NoSuchThing))
import System.Directory (copyFile, removeFile)
import System.INotify (Event (isDirectory, maybeFilePath), withINotify)
import qualified System.INotify as INotify (Event (DeletedSelf, Ignored, Modified), EventVariety (AllEvents, Modify))
import System.IO.Error (ioeGetErrorType)
import System.IO.Temp (emptySystemTempFile, withSystemTempFile)
import System.Posix.IO (OpenFileFlags (append))
import qualified System.Posix.IO as IO (OpenMode (WriteOnly), closeFd, defaultFileFlags, fdWrite, openFd)
import System.Timeout (timeout)
import Test.Hspec (describe, hspec, it, shouldReturn, shouldThrow)

isNoSuchThingErrorType :: IOErrorType -> Bool
isNoSuchThingErrorType NoSuchThing = True
isNoSuchThingErrorType _ = False

data AsyncEvent a = AsyncStarted | AsyncEvent a deriving (Eq, Show)

fromAsyncEvent :: AsyncEvent a -> Maybe a
fromAsyncEvent (AsyncEvent a) = Just a
fromAsyncEvent AsyncStarted = Nothing

tempFileTemplate :: String
tempFileTemplate = "hinotify-conduit.spec"

withEmptySystemTempFile :: String -> (FilePath -> IO a) -> IO a
withEmptySystemTempFile template = bracket (emptySystemTempFile template) removeFile

appendToFile :: FilePath -> String -> IO ()
appendToFile fp str =
  bracket
    (IO.openFd fp IO.WriteOnly Nothing IO.defaultFileFlags {append = True})
    IO.closeFd
    (\fd -> void $ IO.fdWrite fd str)

readTQueueTimeout :: TQueue a -> IO (Maybe a)
readTQueueTimeout = timeout (floor 50e5) . atomically . readTQueue

runSource :: ConduitT () a (ResourceT IO) () -> IO (Async [a], TQueue (AsyncEvent a))
runSource source = do
  q <- newTQueueIO
  let sink = getZipSink $ const <$> ZipSink (C.mapMaybe fromAsyncEvent .| C.sinkList) <*> ZipSink (sinkTQueue q)
  asyncHandle <- async $ runResourceT $ runConduit $ source .| (C.yield AsyncStarted >> C.awaitForever (C.yield . AsyncEvent)) .| sink
  -- wait for AsyncStarted event
  Just AsyncStarted <- readTQueueTimeout q
  threadDelay 1000
  return (asyncHandle, q)

main :: IO ()
main = hspec $
  describe "Data.Conduit.INotify" $ do
    describe "inotifyEventsSource" $ do
      it "fails when file does not exist" $
        let computation :: IO () = withINotify $ \i ->
              do
                (source, _) <- atomically $ inotifyEventsSource i (INotify.AllEvents :| []) "somefile"
                runResourceT $ runConduit $ source .| C.sinkNull
         in computation `shouldThrow` (isNoSuchThingErrorType . ioeGetErrorType)

      it "is possible to interrupt the source via handle" $
        let computation :: IO [INotify.Event] = withINotify $ \i -> withSystemTempFile tempFileTemplate $ \fp _ -> do
              (source, close) <- atomically $ inotifyEventsSource i (INotify.Modify :| []) fp
              (asyncHandle, _) <- runSource source
              atomically close
              Async.wait asyncHandle
         in computation `shouldReturn` mempty

      it "emits event on file modification" $
        let computation :: IO [INotify.Event] = withINotify $ \i -> withSystemTempFile tempFileTemplate $ \fp _ -> do
              (source, close) <- atomically $ inotifyEventsSource i (INotify.Modify :| []) fp
              (asyncHandle, q) <- runSource source

              appendToFile fp "String"
              _ <- readTQueueTimeout q

              atomically close
              Async.wait asyncHandle
         in computation `shouldReturn` [INotify.Modified {isDirectory = False, maybeFilePath = Nothing}]

    describe "inotifyEventsSourceRotate" $ do
      it "fails when file does not exist" $
        let computation :: IO () = withINotify $ \i -> do
              (source, _) <- atomically $ inotifyEventsSourceRotate i (INotify.AllEvents :| []) "somefile"
              runResourceT $ runConduit $ source .| C.sinkNull
         in computation `shouldThrow` (isNoSuchThingErrorType . ioeGetErrorType)

      it "is possible to interrupt the source via handle" $
        let computation :: IO [INotify.Event] = withINotify $ \i -> withSystemTempFile tempFileTemplate $ \fp _ -> do
              (source, close) <- atomically $ inotifyEventsSourceRotate i (INotify.Modify :| []) fp
              (asyncHandle, _) <- runSource source
              atomically close
              Async.wait asyncHandle
         in computation `shouldReturn` mempty

      it "emits event on file modification" $
        let computation :: IO [INotify.Event] = withINotify $ \i -> withSystemTempFile tempFileTemplate $ \fp _ -> do
              (source, close) <- atomically $ inotifyEventsSourceRotate i (INotify.Modify :| []) fp
              (asyncHandle, q) <- runSource source

              appendToFile fp "String"
              _ <- readTQueueTimeout q

              atomically close
              Async.wait asyncHandle
         in computation `shouldReturn` [INotify.Modified {isDirectory = False, maybeFilePath = Nothing}]

      it "emits event on file modification after rotate" $
        let computation :: IO [INotify.Event] = withINotify $ \i ->
              withEmptySystemTempFile tempFileTemplate $ \fp1 ->
                withEmptySystemTempFile tempFileTemplate $ \fp2 -> do
                  (source, close) <- atomically $ inotifyEventsSourceRotate i (INotify.Modify :| []) fp1
                  (asyncHandle, q) <- runSource source

                  -- append to watched file
                  appendToFile fp1 "String"
                  _ <- readTQueueTimeout q

                  -- replace watched file with modified copy
                  copyFile fp2 fp1
                  _ <- readTQueueTimeout q
                  _ <- readTQueueTimeout q

                  -- delay needed to initialize watch in async
                  threadDelay 10000

                  -- append to watched file
                  appendToFile fp1 "String"
                  _ <- readTQueueTimeout q

                  threadDelay 10000

                  atomically close
                  Async.wait asyncHandle
         in computation
              `shouldReturn` [ INotify.Modified {isDirectory = False, maybeFilePath = Nothing},
                               INotify.DeletedSelf,
                               INotify.Ignored,
                               INotify.Modified {isDirectory = False, maybeFilePath = Nothing}
                             ]

    describe "sourceFileFollowModify" $ do
      it "fails when file does not exist" $
        let computation :: IO () = withINotify $ \i -> do
              (source, _) <- atomically $ sourceFileFollowModify i "somefile"
              runResourceT $ runConduit $ source .| C.sinkNull
         in computation `shouldThrow` (isNoSuchThingErrorType . ioeGetErrorType)

      it "is possible to interrupt the source via handle" $
        let computation :: IO [Maybe ByteString] = withINotify $ \i -> withEmptySystemTempFile tempFileTemplate $ \fp -> do
              (source, close) <- atomically $ sourceFileFollowModify i fp
              asyncHandle <- async $ runResourceT $ runConduit $ source .| C.sinkList
              atomically close
              Async.wait asyncHandle
         in computation
              `shouldReturn` [ Nothing, --initial eof
                               Nothing -- eof after handle close
                             ]

      it "file is followed after modification is made" $
        let computation :: IO [Maybe ByteString] = withINotify $ \i -> withEmptySystemTempFile tempFileTemplate $ \fp -> do
              appendToFile fp "Initial"

              (source, close) <- atomically $ sourceFileFollowModify i fp
              (asyncHandle, q) <- runSource source
              -- wait for initial eof
              _ <- readTQueueTimeout q

              appendToFile fp "String"

              -- wait for read after inotify event
              _ <- readTQueueTimeout q

              -- wait for eof
              _ <- readTQueueTimeout q

              atomically close
              -- wait for eof after watch is closed
              _ <- readTQueueTimeout q

              Async.wait asyncHandle
         in computation
              `shouldReturn` [ Just "Initial", -- initial data
                               Nothing, -- initial eof
                               Just "String", -- data after append
                               Nothing, -- eof after append
                               Nothing -- eof after watch is closed
                             ]

    describe "sourceFileFollowModifyRotateWithSeekIO" $ do
      it "fails when file does not exist" $
        let computation :: IO () = withINotify $ \i -> do
              (source, _) <- sourceFileFollowModifyRotateWithSeekIO i "somefile"
              runResourceT $ runConduit $ source .| C.sinkNull
         in computation `shouldThrow` (isNoSuchThingErrorType . ioeGetErrorType)

      it "is possible to interrupt the source via handle" $
        let computation :: IO [Maybe ByteString] = withINotify $ \i -> withEmptySystemTempFile tempFileTemplate $ \fp -> do
              (source, close) <- sourceFileFollowModifyRotateWithSeekIO i fp
              asyncHandle <- async $ runResourceT $ runConduit $ source .| C.sinkList
              atomically close
              Async.wait asyncHandle
         in computation
              `shouldReturn` [ Nothing, --initial eof
                               Nothing -- eof after handle close
                             ]

      it "file is followed after modification is made" $
        let computation :: IO [Maybe ByteString] = withINotify $ \i -> withEmptySystemTempFile tempFileTemplate $ \fp -> do
              appendToFile fp "Initial"

              (source, close) <- sourceFileFollowModifyRotateWithSeekIO i fp
              (asyncHandle, q) <- runSource source
              -- wait for initial eof
              _ <- readTQueueTimeout q

              appendToFile fp "String"

              -- wait for read after inotify event
              _ <- readTQueueTimeout q

              -- wait for eof
              _ <- readTQueueTimeout q

              atomically close
              -- wait for eof after watch is closed
              _ <- readTQueueTimeout q

              Async.wait asyncHandle
         in computation
              `shouldReturn` [ Just "Initial", -- initial data
                               Nothing, -- initial eof
                               Just "String", -- data after append
                               Nothing, -- eof after append
                               Nothing -- eof after watch is closed
                             ]

      it "file is followed after rotation is made" $
        let computation :: IO [Maybe ByteString] = withINotify $ \i -> withEmptySystemTempFile tempFileTemplate $ \fp1 ->
              withEmptySystemTempFile tempFileTemplate $ \fp2 -> do
                appendToFile fp1 "Initial"

                (source, close) <- sourceFileFollowModifyRotateWithSeekIO i fp1
                (asyncHandle, q) <- runSource source
                -- wait for initial eof
                _ <- readTQueueTimeout q

                -- make a copy watched file
                copyFile fp1 fp2

                -- append to a copy
                appendToFile fp2 "String"

                -- replace watched file with modified copy
                copyFile fp2 fp1

                -- wait for read after inotify event
                _ <- readTQueueTimeout q

                -- wait for eof
                _ <- readTQueueTimeout q

                -- delay needed to process watch cleanup
                threadDelay 1000

                atomically close
                -- wait for eof after watch is closed
                _ <- readTQueueTimeout q

                Async.wait asyncHandle
         in computation
              `shouldReturn` [ Just "Initial", -- initial data
                               Nothing, -- initial eof
                               Just "String", -- data after rotate
                               Nothing, -- eof after append
                               Nothing -- eof after watch is closed
                             ]
