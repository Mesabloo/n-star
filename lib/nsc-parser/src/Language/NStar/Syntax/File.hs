{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TupleSections #-}

module Language.NStar.Syntax.File (parseFile) where

import Language.NStar.Syntax.Lexer
import qualified Language.NStar.Syntax.Parser as P
import Language.NStar.Syntax.PostProcessor
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8)
import Text.Diagnose (Diagnostic, reportError, diagnostic, (<++>), printDiagnostic, (<~<))
import Language.NStar.Syntax.Core (Program(..), Section(..))
import qualified Algebra.Graph.AdjacencyMap as G
import qualified Algebra.Graph.Acyclic.AdjacencyMap as AG
import Control.Monad.Except (ExceptT, runExceptT, throwError, liftEither)
import Control.Monad (when, forM, forM_)
import Console.NStar.Flags (ParserFlags, LexerFlags)
import System.Directory (canonicalizePath, makeAbsolute, makeRelativeToCurrentDirectory, doesFileExist, getCurrentDirectory)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (readFile, ByteString)
import Data.Bifunctor (bimap, first, second)
import Data.Located (unLoc, Located((:@)), Position(..))
import System.IO (stderr)
import Data.IORef
import System.FilePath.Posix (equalFilePath, normalise, (</>), isValid, takeFileName)
import Data.List (union, intercalate, groupBy)
import Debug.Trace (traceShow, trace)
import Text.Diagnose.Report (Marker(This))

type CompUnit = ExceptT (Diagnostic [] String Char) IO

parseFile :: (?lexerFlags :: LexerFlags, ?parserFlags :: ParserFlags, ?includePath :: [FilePath])
          => FilePath -> IO ([(FilePath, [String])], Either (Diagnostic [] String Char) Program)
parseFile file = do
  let f = file :@ Position (0, 0) (0, 0) "command-line"

  graph <- newIORef (G.empty, f)
  files <- newIORef []

  includePath <- mapM canonicalizePath ?includePath
  let includePath_ = head <$> groupBy equalFilePath includePath
  includePath <- mapM makeRelativeToCurrentDirectory includePath_
  let ?includePath = includePath

  res <- runExceptT (parseUnit graph files f)
  files <- readIORef files
  pure (files, res)

parseUnit :: (?lexerFlags :: LexerFlags, ?parserFlags :: ParserFlags, ?includePath :: [FilePath])
          => IORef (G.AdjacencyMap (Located FilePath), (Located FilePath))
          -> IORef [(FilePath, [String])]
          -> Located FilePath
          -> CompUnit Program
parseUnit includeGraph includeFiles path@(filePath :@ p) = do
  when (not $ isValid filePath) do
    throwError (invalidFilePath path)

  filesFound <- liftIO $ queryIncludePath ?includePath filePath

  filePath <- case filesFound of
    []  -> throwError (unknownFile ?includePath path)
    [f] -> pure f
    fs  -> throwError (multipleFilesFound fs)

  fileContent <- liftIO $ readFileUtf8 filePath
  let content = (filePath, lines $ Text.unpack fileContent)

  liftIO $ modifyIORef' includeFiles (content :)

  (tokens, warns) <- liftEither $ lexFile filePath fileContent
  liftIO $ printDiagnostic True stderr (warns <~< content)
  (ast, warns) <- liftEither $ P.parseFile filePath tokens
  liftIO $ printDiagnostic True stderr (warns <~< content)

  let Program sections = ast
  newSections <- mconcat <$> forM sections \ case
    IncludeS files :@ _ -> do
      includedFiles <- forM files \ newFile -> do
        let f = Text.unpack <$> newFile

        liftIO $ modifyIORef' includeGraph (first (`G.overlay` G.edge (filePath :@ p) f))
        checkCycles =<< liftIO (readIORef includeGraph)

        alreadyIncluded <- fmap fst <$> liftIO (readIORef includeFiles)
        if unLoc f `elem` alreadyIncluded
        then pure (Program [])
        else parseUnit includeGraph includeFiles f

      pure $ mconcat (toSections <$> includedFiles)
    s                   -> pure [s]

  pure (postProcessAST $ Program newSections)
  where toSections (Program ss) = ss

------------------------------------------------------------------------------------------------------------------------------

queryIncludePath :: [FilePath] -> FilePath -> IO [FilePath]
queryIncludePath [] _     = pure []
queryIncludePath (p:ps) f = do
  let path = p </> f

  exists <- doesFileExist path
  if exists
  then (path :) <$> queryIncludePath ps f
  else queryIncludePath ps f

-- | Strictly read a file into a 'Text' using a UTF-8 character
-- encoding. In the event of a character encoding error, a Unicode
-- replacement character will be used (a.k.a., @lenientDecode@).
readFileUtf8 :: FilePath -> IO Text
readFileUtf8 = fmap decodeUtf8 . Data.ByteString.readFile

unknownFile :: [FilePath] -> Located FilePath -> Diagnostic [] String Char
unknownFile ip (f :@ p) =
  let includePath =
        if null ip
        then ""
        else "\nCurrent include path:\n- " <> intercalate "\n- " (normalise <$> ip)
  in diagnostic <++> reportError ("File '" <> f <> "' not found" <> includePath) [ (p, This "") ] []

invalidFilePath :: Located FilePath -> Diagnostic [] String Char
invalidFilePath (f :@ p) = diagnostic <++> reportError ("Invalid file path '" <> f <> "'") [ (p, This "") ] []

multipleFilesFound :: [FilePath] -> Diagnostic [] String Char
multipleFilesFound fs@(f:_) =
  let paths = mappend "- " <$> fs
  in diagnostic <++> reportError ("Cannot include file '" <> takeFileName f <> "' because more than one has been found in the include path:\n" <> intercalate "\n" paths) [] []

checkCycles :: (G.AdjacencyMap (Located FilePath), Located FilePath) -> CompUnit ()
checkCycles (g, root) = dfs [root] g root

dfs :: [Located FilePath] -> G.AdjacencyMap (Located FilePath) -> Located FilePath -> CompUnit ()
dfs stack g root =
  forM_ (G.postSet root g) \ p -> do
    when (p `elem` stack) do
      throwError (cyclicInclude $ dropWhile (/= p) $ reverse $ p:stack)
    dfs (p:stack) g p

cyclicInclude :: [Located FilePath] -> Diagnostic [] String Char
cyclicInclude cycle =
  let positions = flip map cycle \ (f :@ p) -> ("- '" <> f <> "' is included by '" <> file p <> "'")
  in diagnostic <++> reportError ("Cyclic includes detected:\n" <> intercalate "\n" positions) [] []
