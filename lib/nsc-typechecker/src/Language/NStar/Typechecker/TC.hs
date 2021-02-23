{-# LANGUAGE RecordWildCards #-}

module Language.NStar.Typechecker.TC where

import Control.Monad.State (StateT, modify)
import Control.Monad.Writer (WriterT)
import Control.Monad.Except (Except)
import Data.Map (Map)
import Language.NStar.Typechecker.Env (Env)
import qualified Language.NStar.Typechecker.Env as Env
import Data.Located (Located)
import Data.Text (Text)
import Language.NStar.Typechecker.Core
import Data.Bifunctor (first)
import Language.NStar.Typechecker.Errors (TypecheckError, TypecheckWarning)

type TC a = StateT TCContext (WriterT [TypecheckWarning] (Except TypecheckError)) a

data TCContext
  = TCCtx
      (Env Type)    -- ^ Bindings in code sections
      (Env Type)    -- ^ Bindings in data sections

instance Semigroup TCContext where
  TCCtx e1 m1 <> TCCtx e2 m2 = TCCtx (e1 <> e2) (m1 <> m2)

instance Monoid TCContext where
  mempty = TCCtx mempty mempty

type Typechecker a = StateT (Integer, Context) (WriterT [TypecheckWarning] (Except TypecheckError)) a

-- | The data type of contexts in typechecking.
data Context
  = Ctx
  { xiC     :: Env Type                               -- ^ An 'Env'ironment containing labels associated to their expected contexts
  , xiD     :: Env Type                               -- ^ The available labels in the @data@ sections
  , gamma   :: Env Kind                               -- ^ The current kindchecking context
  , chi     :: Map (Located Register) (Located Type)  -- ^ The current register context
  , sigma   :: Located Type                           -- ^ The current stack
  , epsilon :: Located Type                           -- ^ The current continuation
  }

-- | Adds a type to the environment.
addType :: Located Text -> Located Type -> TC ()
addType k v = modify modifyTypeContext
  where modifyTypeContext (TCCtx e1 m1) = TCCtx (Env.insert k v e1) m1

addDataLabel :: Located Text -> Located Type -> TC ()
addDataLabel k v = modify modifyDataSections
  where modifyDataSections (TCCtx e1 m1) = TCCtx e1 (Env.insert k v m1)

-- | Increments the counter in the 'State' by one, effectively simulating a @counter++@ operation.
incrementCounter :: Typechecker ()
incrementCounter = modify $ first (+ 1)

--------------------------------------------------------
