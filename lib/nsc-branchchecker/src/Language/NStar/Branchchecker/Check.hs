module Language.NStar.Branchchecker.Check (branchcheck) where

import Language.NStar.Branchchecker.FlowGraph
import Algebra.Graph.Labelled.AdjacencyMap ((-<), (>-))
import qualified Algebra.Graph.Labelled.AdjacencyMap as Graph
import Text.Diagnose (Diagnostic, diagnostic, (<++>), Position(..))
import Control.Monad.Except
import Control.Monad.State
import Language.NStar.Branchchecker.Errors
import Language.NStar.Typechecker.Core
import Data.Bifunctor (first, second)
import Control.Monad (forM_, unless)
import Data.Located (Located(..), unLoc)
import Data.Text (Text)
import Data.List (foldl')
import Data.Functor ((<&>))
import qualified Data.Set as Set
import Control.Monad.Reader
import Debug.Trace (traceShow)
import Internal.Error (internalError)

type Checker a = StateT (Maybe (Located Text), JumpGraph) (Except BranchcheckerError) a

branchcheck :: TypedProgram -> Either (Diagnostic s String m) ()
branchcheck p = first toDiagnostic $ runExcept (evalStateT (branchcheckProgram p) (Nothing, "_start"-<Call>-"main"))
  where toDiagnostic = (diagnostic <++>) . fromBranchcheckerError                              --  ^^^^^^^^^^^ "a-<i>-b" really means "a -i-> b"

branchcheckProgram :: TypedProgram -> Checker ()
branchcheckProgram (TProgram stts) = do
  -- set current scope to Nothing
  forM_ stts registerEdges
  checkJumpgraphForConsistency

registerEdges :: Located TypedStatement -> Checker ()
registerEdges (TLabel name :@ _) =
  modify (first (const (Just name)))
registerEdges (TInstr i _ :@ p) = case unLoc i of
  RET -> do
    (lbl, graph) <- get
    let Just (label :@ _) = lbl

    -- fetch upwards the last call that got to the current label
    -- and insert an edge for each of the parents of those calls.
    let parents  = fetchAllCallParents label graph
        newGraph = foldl' (\ g p -> Graph.overlay g (label-<Ret>-p)) graph parents
    modify (second (const newGraph))

    pure ()

  -- other instruction do not act on the control flow.
  _ -> pure ()

fetchAllCallParents :: Text -> JumpGraph -> [Text]
fetchAllCallParents root graph =
  let predec  = Graph.preSet root graph
      labels  = Set.toList predec <&> \ p -> (p, Graph.edgeLabel p root graph)
      parents = labels >>= \ (p, l) -> case l of
        Call -> [p]
        _    -> fetchAllCallParents p (Graph.removeEdge p root graph)
  in parents

-----------------------------------------------------------------------------

checkJumpgraphForConsistency :: Checker ()
checkJumpgraphForConsistency = do
  checkCallsHaveRet

  pure ()

checkCallsHaveRet :: Checker ()
checkCallsHaveRet = do
  graph <- gets snd
  let allCalls = filter (\ (j, _, _) -> j == Call) (Graph.edgeList graph)

  unless (null allCalls) do
    let c@(_, _, r):_ = allCalls
    -- the first call is ALWAYS the call from _start to main
    let remaining     = execState (checks r graph) [c]
    case remaining of
      []           -> pure ()
      (_, _, c):rs -> throwError (NonReturningCall (c :@ Position (1, 1) (1, 5) "test"))
  where
    checks root g = do
      let succs  = Graph.postSet root g
          labels = Set.toList succs <&> \ l -> (l, Graph.edgeLabel root l g)
      forM_ labels \ (s, j) -> case j of
        Call -> do
          push (Call, root, s)
          checks s (Graph.removeEdge root s g)
        Jump -> do
          checks s (Graph.removeEdge root s g)
        Ret -> do
          pop
    pop = gets tail >>= put
    push = modify . (:)