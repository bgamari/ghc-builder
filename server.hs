
{-# LANGUAGE PatternGuards #-}

module Main where

import BuildStep
import Utils

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Char
import Data.List
import Network.Socket
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO

baseDir :: FilePath
baseDir = "data"

main :: IO ()
main = do args <- getArgs
          case args of
              []              -> withSocketsDo runServer
              ["init"]        -> initServer
              ["add", client] -> addClient client
              _               -> die "Bad args"

initServer :: IO ()
initServer = do -- XXX We really ought to catch an already-exists
                -- exception and handle it properly
                createDirectory baseDir
                createDirectory (baseDir </> "clients")

addClient :: String -> IO ()
addClient client
 | null client = die "Null client name!"
 | not (all isAlpha client) = die "Bad client name"
 | otherwise = do -- XXX We really ought to catch an already-exists
                  -- exception and handle it properly
                  let clientDir = baseDir </> "clients" </> client
                  createDirectory clientDir
                  createDirectory (clientDir </> "builds")
                  writeToFile (clientDir </> "last_build_step_uploaded")
                              (0 :: BuildNum, 0 :: BuildStepNum)
                  writeToFile (clientDir </> "last_build_num_allocated")
                              (0 :: BuildNum)
                  putStrLn "OK, client added"

runServer :: IO ()
runServer =
    do addrinfos <- getAddrInfo Nothing Nothing (Just "3000")
       let serveraddr = head addrinfos
       bracket (socket (addrFamily serveraddr) Stream defaultProtocol)
               sClose
               (listenForClients serveraddr)

listenForClients :: AddrInfo -> Socket -> IO ()
listenForClients serveraddr sock
 = do bindSocket sock (addrAddress serveraddr)
      listen sock 1
      let mainLoop = do (conn, _) <- accept sock
                        h <- socketToHandle conn ReadWriteMode
                        hSetBuffering h LineBuffering
                        forkIO $ authClient h
                        mainLoop
      mainLoop

authClient :: Handle -> IO ()
authClient h = do msg <- hGetLine h
                  when True $ -- XXX (v >= Verbose) $
                      putStrLn ("Received: " ++ show msg)
                  case stripPrefix "AUTH " msg of
                      Just xs ->
                          case break (' ' ==) xs of
                              (user, ' ' : _pass) ->
                                  -- XXX actually do authentication
                                  do let client = Client {
                                                      c_handle = h,
                                                      c_user = user,
                                                      -- XXX:
                                                      c_verbosity = Verbose
                                                  }
                                     sendClient client "200 authenticated"
                                     handleClient client
                              _ ->
                                  do hPutStrLn h "500 I don't understand"
                                     authClient h
                      Nothing ->
                          case msg of
                              "HELP" ->
                                  -- XXX
                                  do hPutStrLn h "500 I don't understand"
                                     authClient h
                              _ ->
                                  do hPutStrLn h "500 I don't understand"
                                     authClient h

data Verbosity = Silent | Normal | Verbose | Deafening
    deriving (Eq, Ord, Show, Read)

data Client = Client {
                  c_handle :: Handle,
                  c_user :: String,
                  c_verbosity :: Verbosity
              }

sendClient :: Client -> String -> IO ()
sendClient c str = do when (c_verbosity c >= Verbose) $
                          putStrLn ("Sending: " ++ show str)
                      hPutStrLn (c_handle c) str

handleClient :: Client -> IO ()
handleClient c = do talk
                    handleClient c
    where h = c_handle c
          v = c_verbosity c
          talk :: IO ()
          talk = do msg <- hGetLine h
                    when (v >= Verbose) $
                        putStrLn ("Received: " ++ show msg)
                    case msg of
                        -- XXX "HELP"
                        "BUILD INSTRUCTIONS" ->
                            do sendClient c "201 Instructions follow"
                               let lastBuildNumFile = baseDir </> "clients" </> c_user c </> "last_build_num_allocated"
                               lastBuildNum <- readFromFile lastBuildNumFile
                               let thisBuildNum = lastBuildNum + 1
                               writeToFile lastBuildNumFile thisBuildNum
                               sendSizedThing h $ mkBuildInstructions thisBuildNum
                        _
                         | Just xs <- stripPrefix "UPLOAD " msg,
                           (ys, ' ' : zs) <- break (' ' ==) xs,
                           Just buildNum <- maybeRead ys,
                           Just buildStepNum <- maybeRead zs ->
                            receiveBuildStep c buildNum buildStepNum
                         | otherwise ->
                            hPutStrLn h "500 I don't understand"
                    talk

receiveBuildStep :: Client -> BuildNum -> BuildStepNum -> IO ()
receiveBuildStep c buildNum buildStepNum
 = do let h = c_handle c
          userDir = baseDir </> "clients" </> c_user c
          buildDir = userDir </> show buildNum
          buildStepDir = buildDir </> show buildStepNum
      createDirectoryIfMissing False buildDir
      createDirectoryIfMissing False buildStepDir
      -- Get the program
      sendClient c "203 Send program"
      prog <- readSizedThing h
      writeBinaryFile (buildStepDir </> "prog") (show (prog :: String))
      -- Get the args
      sendClient c "203 Send args"
      args <- readSizedThing h
      writeBinaryFile (buildStepDir </> "args") (show (args :: [String]))
      -- Get the exit code
      sendClient c "203 Send exit code"
      ec <- readSizedThing h
      writeBinaryFile (buildStepDir </> "exitcode") (show (ec :: ExitCode))
      -- Get the stdout
      sendClient c "203 Send stdout"
      sOut <- getSizedThing h
      writeBinaryFile (buildStepDir </> "stdout") sOut
      -- Get the stderr
      sendClient c "203 Send stderr"
      sErr <- getSizedThing h
      writeBinaryFile (buildStepDir </> "stderr") sErr
      -- update the "last buildnum / buildstep received" counters
      let lastFile = userDir </> "last_build_step_uploaded"
      l <- readFromFile lastFile
      let l' = l `max` (buildNum, buildStepNum)
      writeToFile lastFile l'
      -- and tell the client that we're done, so it can delete its copy
      -- of the files
      sendClient c "200 Got it, thanks!"

mkBuildInstructions :: BuildNum -> BuildInstructions
mkBuildInstructions bn = (bn, [(1, bs1), (2, bs2)])
    where bs1 = BuildStep {
                    bs_name = "Test build step",
                    bs_prog = "/bin/echo",
                    bs_args = ["arg1", "arg2", "arg3"]
                }
          bs2 = BuildStep {
                    bs_name = "Second test build step",
                    bs_prog = "/bin/echo",
                    bs_args = ["argx1", "argx2", "argx3"]
                }

