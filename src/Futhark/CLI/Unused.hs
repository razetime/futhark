{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use newtype instead of data" #-}

-- | @futhark doc@
module Futhark.CLI.Unused (main) where

import Control.Monad.State
import Futhark.Compiler (dumpError, newFutharkConfig, readProgramFiles)
import Futhark.Pipeline (Verbosity (..), runFutharkM)
import Futhark.Util.Options
import Language.Futhark.Unused
import System.Exit

main :: String -> [String] -> IO ()
main = mainWithOptions initialCheckConfig [] "files..." find
  where
    find [] _ = Nothing
    find files _ = Just $ printUnused files

printUnused :: [FilePath] -> IO ()
printUnused files = do
  res <- runFutharkM (readProgramFiles [] files) Verbose
  case res of
    Left err -> liftIO $ do
      dumpError newFutharkConfig err
      exitWith $ ExitFailure 2
    Right (_, imp, _) -> do
      -- let decs = getDecs fm
      -- print $ length decs
      -- print $ head decs
      print $ map fst imp
      print $ findUnused files imp

data CheckConfig = CheckConfig Bool

initialCheckConfig :: CheckConfig
initialCheckConfig = CheckConfig False
