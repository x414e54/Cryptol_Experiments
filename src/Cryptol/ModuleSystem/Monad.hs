-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
module Cryptol.ModuleSystem.Monad where

import           Cryptol.Eval (EvalEnv)

import qualified Cryptol.Eval.Monad           as E
import           Cryptol.ModuleSystem.Env
import           Cryptol.ModuleSystem.Interface
import           Cryptol.ModuleSystem.Name (FreshM(..),Supply)
import           Cryptol.ModuleSystem.Renamer
                     (RenamerError(),RenamerWarning(),NamingEnv)
import qualified Cryptol.Parser     as Parser
import qualified Cryptol.Parser.AST as P
import           Cryptol.Parser.Position (Located)
import           Cryptol.Utils.Panic (panic)
import qualified Cryptol.Parser.NoPat as NoPat
import qualified Cryptol.Parser.NoInclude as NoInc
import qualified Cryptol.TypeCheck as T
import qualified Cryptol.TypeCheck.AST as T
import           Cryptol.Parser.Position (Range)
import           Cryptol.Utils.Ident (interactiveName)
import           Cryptol.Utils.PP

import Control.Monad.IO.Class
import Control.Exception (IOException)
import Data.Function (on)
import Data.Maybe (isJust)
import MonadLib

import GHC.Generics (Generic)
import Control.DeepSeq

import Prelude ()
import Prelude.Compat

-- Errors ----------------------------------------------------------------------

data ImportSource
  = FromModule P.ModName
  | FromImport (Located P.Import)
    deriving (Show, Generic, NFData)

instance Eq ImportSource where
  (==) = (==) `on` importedModule

instance PP ImportSource where
  ppPrec _ is = case is of
    FromModule n  -> text "module name" <+> pp n
    FromImport li -> text "import of module" <+> pp (P.iModule (P.thing li))

importedModule :: ImportSource -> P.ModName
importedModule is = case is of
  FromModule n  -> n
  FromImport li -> P.iModule (P.thing li)


data ModuleError
  = ModuleNotFound P.ModName [FilePath]
    -- ^ Unable to find the module given, tried looking in these paths
  | CantFindFile FilePath
    -- ^ Unable to open a file
  | OtherIOError FilePath IOException
    -- ^ Some other IO error occurred while reading this file
  | ModuleParseError FilePath Parser.ParseError
    -- ^ Generated this parse error when parsing the file for module m
  | RecursiveModules [ImportSource]
    -- ^ Recursive module group discovered
  | RenamerErrors ImportSource [RenamerError]
    -- ^ Problems during the renaming phase
  | NoPatErrors ImportSource [NoPat.Error]
    -- ^ Problems during the NoPat phase
  | NoIncludeErrors ImportSource [NoInc.IncludeError]
    -- ^ Problems during the NoInclude phase
  | TypeCheckingFailed ImportSource [(Range,T.Error)]
    -- ^ Problems during type checking
  | OtherFailure String
    -- ^ Problems after type checking, eg. specialization
  | ModuleNameMismatch P.ModName (Located P.ModName)
    -- ^ Module loaded by 'import' statement has the wrong module name
  | DuplicateModuleName P.ModName FilePath FilePath
    -- ^ Two modules loaded from different files have the same module name
    deriving (Show)

instance NFData ModuleError where
  rnf e = case e of
    ModuleNotFound src path              -> src `deepseq` path `deepseq` ()
    CantFindFile path                    -> path `deepseq` ()
    OtherIOError path exn                -> path `deepseq` exn `seq` ()
    ModuleParseError source err          -> source `deepseq` err `deepseq` ()
    RecursiveModules mods                -> mods `deepseq` ()
    RenamerErrors src errs               -> src `deepseq` errs `deepseq` ()
    NoPatErrors src errs                 -> src `deepseq` errs `deepseq` ()
    NoIncludeErrors src errs             -> src `deepseq` errs `deepseq` ()
    TypeCheckingFailed src errs          -> src `deepseq` errs `deepseq` ()
    ModuleNameMismatch expected found    ->
      expected `deepseq` found `deepseq` ()
    DuplicateModuleName name path1 path2 ->
      name `deepseq` path1 `deepseq` path2 `deepseq` ()
    OtherFailure x                       -> x `deepseq` ()

instance PP ModuleError where
  ppPrec _ e = case e of

    ModuleNotFound src path ->
      text "[error]" <+>
      text "Could not find module" <+> pp src
      $$
      hang (text "Searched paths:")
         4 (vcat (map text path))
      $$
      text "Set the CRYPTOLPATH environment variable to search more directories"

    CantFindFile path ->
      text "[error]" <+>
      text "can't find file:" <+> text path

    OtherIOError path exn ->
      hang (text "[error]" <+>
            text "IO error while loading file:" <+> text path <> colon)
         4 (text (show exn))

    ModuleParseError _source err -> Parser.ppError err

    RecursiveModules mods ->
      hang (text "[error] module imports form a cycle:")
         4 (vcat (map pp (reverse mods)))

    RenamerErrors _src errs -> vcat (map pp errs)

    NoPatErrors _src errs -> vcat (map pp errs)

    NoIncludeErrors _src errs -> vcat (map NoInc.ppIncludeError errs)

    TypeCheckingFailed _src errs -> vcat (map T.ppError errs)

    ModuleNameMismatch expected found ->
      hang (text "[error]" <+> pp (P.srcRange found) <> char ':')
         4 (vcat [ text "File name does not match module name:"
                 , text "Saw:"      <+> pp (P.thing found)
                 , text "Expected:" <+> pp expected
                 ])

    DuplicateModuleName name path1 path2 ->
      hang (text "[error] module" <+> pp name <+>
            text "is defined in multiple files:")
         4 (vcat [text path1, text path2])

    OtherFailure x -> text x




moduleNotFound :: P.ModName -> [FilePath] -> ModuleM a
moduleNotFound name paths = ModuleT (raise (ModuleNotFound name paths))

cantFindFile :: FilePath -> ModuleM a
cantFindFile path = ModuleT (raise (CantFindFile path))

otherIOError :: FilePath -> IOException -> ModuleM a
otherIOError path exn = ModuleT (raise (OtherIOError path exn))

moduleParseError :: FilePath -> Parser.ParseError -> ModuleM a
moduleParseError path err =
  ModuleT (raise (ModuleParseError path err))

recursiveModules :: [ImportSource] -> ModuleM a
recursiveModules loaded = ModuleT (raise (RecursiveModules loaded))

renamerErrors :: [RenamerError] -> ModuleM a
renamerErrors errs = do
  src <- getImportSource
  ModuleT (raise (RenamerErrors src errs))

noPatErrors :: [NoPat.Error] -> ModuleM a
noPatErrors errs = do
  src <- getImportSource
  ModuleT (raise (NoPatErrors src errs))

noIncludeErrors :: [NoInc.IncludeError] -> ModuleM a
noIncludeErrors errs = do
  src <- getImportSource
  ModuleT (raise (NoIncludeErrors src errs))

typeCheckingFailed :: [(Range,T.Error)] -> ModuleM a
typeCheckingFailed errs = do
  src <- getImportSource
  ModuleT (raise (TypeCheckingFailed src errs))

moduleNameMismatch :: P.ModName -> Located P.ModName -> ModuleM a
moduleNameMismatch expected found =
  ModuleT (raise (ModuleNameMismatch expected found))

duplicateModuleName :: P.ModName -> FilePath -> FilePath -> ModuleM a
duplicateModuleName name path1 path2 =
  ModuleT (raise (DuplicateModuleName name path1 path2))


-- Warnings --------------------------------------------------------------------

data ModuleWarning
  = TypeCheckWarnings [(Range,T.Warning)]
  | RenamerWarnings [RenamerWarning]
    deriving (Show, Generic, NFData)

instance PP ModuleWarning where
  ppPrec _ w = case w of
    TypeCheckWarnings ws -> vcat (map T.ppWarning ws)
    RenamerWarnings ws   -> vcat (map pp ws)

warn :: [ModuleWarning] -> ModuleM ()
warn  = ModuleT . put

typeCheckWarnings :: [(Range,T.Warning)] -> ModuleM ()
typeCheckWarnings ws
  | null ws   = return ()
  | otherwise = warn [TypeCheckWarnings ws]

renamerWarnings :: [RenamerWarning] -> ModuleM ()
renamerWarnings ws
  | null ws   = return ()
  | otherwise = warn [RenamerWarnings ws]


-- Module System Monad ---------------------------------------------------------

data RO = RO
  { roLoading :: [ImportSource]
  }

emptyRO :: RO
emptyRO  = RO { roLoading = [] }

newtype ModuleT m a = ModuleT
  { unModuleT :: ReaderT RO (StateT ModuleEnv
                    (ExceptionT ModuleError (WriterT [ModuleWarning] m))) a
  }

instance Monad m => Functor (ModuleT m) where
  {-# INLINE fmap #-}
  fmap f m      = ModuleT (fmap f (unModuleT m))

instance Monad m => Applicative (ModuleT m) where
  {-# INLINE pure #-}
  pure x = ModuleT (pure x)

  {-# INLINE (<*>) #-}
  l <*> r = ModuleT (unModuleT l <*> unModuleT r)

instance Monad m => Monad (ModuleT m) where
  {-# INLINE return #-}
  return x      = ModuleT (return x)

  {-# INLINE (>>=) #-}
  m >>= f       = ModuleT (unModuleT m >>= unModuleT . f)
  {-# INLINE fail #-}
  fail          = ModuleT . raise . OtherFailure

instance MonadT ModuleT where
  {-# INLINE lift #-}
  lift = ModuleT . lift . lift . lift . lift

instance Monad m => FreshM (ModuleT m) where
  liftSupply f = ModuleT $
    do me <- get
       let (a,s') = f (meSupply me)
       set $! me { meSupply = s' }
       return a

instance MonadIO m => MonadIO (ModuleT m) where
  liftIO m = lift $ liftIO m

runModuleT :: Monad m
           => ModuleEnv
           -> ModuleT m a
           -> m (Either ModuleError (a, ModuleEnv), [ModuleWarning])
runModuleT env m =
    runWriterT
  $ runExceptionT
  $ runStateT env
  $ runReaderT emptyRO
  $ unModuleT m

-- runM (unModuleT m) emptyRO env

type ModuleM = ModuleT IO

runModuleM :: ModuleEnv -> ModuleM a
           -> IO (Either ModuleError (a,ModuleEnv),[ModuleWarning])
runModuleM = runModuleT



io :: BaseM m IO => IO a -> ModuleT m a
io m = ModuleT (inBase m)

getModuleEnv :: Monad m => ModuleT m ModuleEnv
getModuleEnv = ModuleT get

setModuleEnv :: Monad m => ModuleEnv -> ModuleT m ()
setModuleEnv = ModuleT . set

modifyModuleEnv :: Monad m => (ModuleEnv -> ModuleEnv) -> ModuleT m ()
modifyModuleEnv f = ModuleT $ do
  env <- get
  set $! f env

isLoaded :: P.ModName -> ModuleM Bool
isLoaded mn = ModuleT $ do
  env <- get
  return (isJust (lookupModule mn env))

loadingImport :: Located P.Import -> ModuleM a -> ModuleM a
loadingImport  = loading . FromImport

loadingModule :: P.ModName -> ModuleM a -> ModuleM a
loadingModule  = loading . FromModule

-- | Push an "interactive" context onto the loading stack.  A bit of a hack, as
-- it uses a faked module name
interactive :: ModuleM a -> ModuleM a
interactive  = loadingModule interactiveName

loading :: ImportSource -> ModuleM a -> ModuleM a
loading src m = ModuleT $ do
  ro <- ask
  let ro'  = ro { roLoading = src : roLoading ro }

  -- check for recursive modules
  when (src `elem` roLoading ro) (raise (RecursiveModules (roLoading ro')))

  local ro' (unModuleT m)

-- | Get the currently focused import source.
getImportSource :: ModuleM ImportSource
getImportSource  = ModuleT $ do
  ro <- ask
  case roLoading ro of
    is : _ -> return is
    _      -> panic "ModuleSystem: getImportSource" ["Import stack is empty"]


getIface :: P.ModName -> ModuleM Iface
getIface mn = ModuleT $ do
  env <- get
  case lookupModule mn env of
    Just lm -> return (lmInterface lm)
    Nothing -> panic "ModuleSystem" ["Interface not available "]

getNameSeeds :: ModuleM T.NameSeeds
getNameSeeds  = ModuleT (meNameSeeds `fmap` get)

getSupply :: ModuleM Supply
getSupply  = ModuleT (meSupply `fmap` get)

getMonoBinds :: ModuleM Bool
getMonoBinds  = ModuleT (meMonoBinds `fmap` get)

setMonoBinds :: Bool -> ModuleM ()
setMonoBinds b = ModuleT $ do
  env <- get
  set $! env { meMonoBinds = b }

setNameSeeds :: T.NameSeeds -> ModuleM ()
setNameSeeds seeds = ModuleT $ do
  env <- get
  set $! env { meNameSeeds = seeds }

setSupply :: Supply -> ModuleM ()
setSupply supply = ModuleT $
  do env <- get
     set $! env { meSupply = supply }

-- | Remove a module from the set of loaded module, by its path.
unloadModule :: FilePath -> ModuleM ()
unloadModule path = ModuleT $ do
  env <- get
  set $! env { meLoadedModules = removeLoadedModule path (meLoadedModules env) }

loadedModule :: FilePath -> T.Module -> ModuleM ()
loadedModule path m = ModuleT $ do
  env <- get
  set $! env { meLoadedModules = addLoadedModule path m (meLoadedModules env) }

modifyEvalEnv :: (EvalEnv -> E.Eval EvalEnv) -> ModuleM ()
modifyEvalEnv f = ModuleT $ do
  env <- get
  let evalEnv = meEvalEnv env
  evalEnv' <- inBase $ E.runEval (f evalEnv)
  set $! env { meEvalEnv = evalEnv' }

getEvalEnv :: ModuleM EvalEnv
getEvalEnv  = ModuleT (meEvalEnv `fmap` get)

getFocusedModule :: ModuleM (Maybe P.ModName)
getFocusedModule  = ModuleT (meFocusedModule `fmap` get)

setFocusedModule :: P.ModName -> ModuleM ()
setFocusedModule n = ModuleT $ do
  me <- get
  set $! me { meFocusedModule = Just n }

getSearchPath :: ModuleM [FilePath]
getSearchPath  = ModuleT (meSearchPath `fmap` get)

-- | Run a 'ModuleM' action in a context with a prepended search
-- path. Useful for temporarily looking in other places while
-- resolving imports, for example.
withPrependedSearchPath :: [FilePath] -> ModuleM a -> ModuleM a
withPrependedSearchPath fps m = ModuleT $ do
  env0 <- get
  let fps0 = meSearchPath env0
  set $! env0 { meSearchPath = fps ++ fps0 }
  x <- unModuleT m
  env <- get
  set $! env { meSearchPath = fps0 }
  return x

-- XXX improve error handling here
getFocusedEnv :: ModuleM (IfaceDecls,NamingEnv,NameDisp)
getFocusedEnv  = ModuleT (focusedEnv `fmap` get)

getQualifiedEnv :: ModuleM IfaceDecls
getQualifiedEnv  = ModuleT (qualifiedEnv `fmap` get)

getDynEnv :: ModuleM DynamicEnv
getDynEnv  = ModuleT (meDynEnv `fmap` get)

setDynEnv :: DynamicEnv -> ModuleM ()
setDynEnv denv = ModuleT $ do
  me <- get
  set $! me { meDynEnv = denv }

setSolver :: T.SolverConfig -> ModuleM ()
setSolver cfg = ModuleT $ do
  me <- get
  set $! me { meSolverConfig = cfg }

getSolverConfig :: ModuleM T.SolverConfig
getSolverConfig  = ModuleT $ do
  me <- get
  return (meSolverConfig me)
