module Test where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import System.Directory
import System.FilePath.ByteString (encodeFilePath)
import System.INotify (withINotify)
import qualified System.INotify as INotify (EventVariety (AllEvents), addWatch, removeWatch)
import qualified System.IO as IO

testFileRemoval path = do
  IO.writeFile path ""
  withINotify $ \inot ->
    bracket
      (INotify.addWatch inot [INotify.AllEvents] (encodeFilePath path) print)
      INotify.removeWatch
      (\wd -> threadDelay 1000000 >> removeFile path >> threadDelay 1000000)
