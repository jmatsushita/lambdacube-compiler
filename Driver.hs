{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
module Driver
    ( module Driver
    , pattern ExpN
    , IR.Backend(..)
    ) where

import Data.List
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Foldable (Foldable, toList)
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Except
import Control.Monad.Identity
import Control.Arrow hiding ((<+>))
import System.Directory
import System.FilePath
import Debug.Trace

import Pretty hiding ((</>))
import Type
import qualified IR as IR
import qualified CoreToIR as IR
import Parser
import Typecheck hiding (Exp(..))

type Modules = Map FilePath PolyEnv

type MM = ReaderT [FilePath] (ErrorT (StateT Modules (VarMT IO)))

compileMain :: IR.Backend -> FilePath -> MName -> IO (Either String (IR.Pipeline, Infos))
compileMain backend path fname = fmap (IR.compilePipeline backend *** id) <$> reducedMain path fname

reducedMain :: FilePath -> MName -> IO (Either String (Exp, Infos))
reducedMain path fname =
    runMM [path] $ parseAndToCoreMain fname

runMM :: [FilePath] -> MM a -> IO (Either String a) 
runMM paths
    = flip evalStateT 0
    . flip evalStateT mempty
    . fmap (either (Left . show) Right)
    . runExceptT
    . flip runReaderT paths

catchMM :: MM a -> MM (Either String a)
catchMM = mapReaderT $ \m -> lift $ either (Left . show) Right <$> runExceptT m

parseAndToCoreMain :: MName -> MM (Exp, Infos)
parseAndToCoreMain m = either (throwErrorTCM . text) return =<< getDef m (ExpN "main")

loadModule :: MName -> MM (FilePath, PolyEnv)
loadModule mname = do
  fnames <- asks $ map $ flip lcModuleFile mname
  let
    find :: [FilePath] -> MM (FilePath, PolyEnv)
    find [] = throwErrorTCM $ "can't find module" <+> hsep (map text fnames)
    find (fname: fs) = do
     b <- liftIO $ doesFileExist fname
     if not b then find fs
     else do
       c <- gets $ Map.lookup fname
       case c of
         Just m -> return (fname, m)
         _ -> do
            (src, e) <- lift $ mapExceptT (lift . lift) $ parseLC fname
            ms <- mapM loadModule $ moduleImports e
            mapError (InFile src) $ trace ("loading " ++ fname) $ do
                env <- joinPolyEnvs $ map snd ms
                x <- lift $ mapExceptT (lift . mapStateT liftIdentity) $ inference_ env e
                modify $ Map.insert fname x
                return (fname, x)

  find fnames

lcModuleFile path n = path </> (showN n ++ ".lc")

getType = getType_ "Prelude"
getType_ m n = either putStrLn (putStrLn . ppShow) =<< runMM ["./tests/accept"] (getDef_ (ExpN m) (ExpN n))

getDef_ :: MName -> EName -> MM Exp
getDef_ m d = do
    (fm, pe) <- loadModule m
    fmap (\(m, (_, x)) -> typingToTy m x) $ lift $ lift $ lift $ mapStateT liftIdentity $ runWriterT' $ either undefined id (getPolyEnv pe Map.! d) $ ""

getDef :: MName -> EName -> MM (Either String (Exp, Infos))
getDef m d = do
    (fm, pe) <- loadModule m
    case Map.lookup d $ getTEnv $ thunkEnv pe of
        Just (ISubst th) -> return $ Right (reduce th, infos pe)
        Nothing -> return $ Left "not found"
        _ -> throwErrorTCM "not found?"

