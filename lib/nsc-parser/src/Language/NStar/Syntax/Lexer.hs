{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

{-|
  Module: Language.NStar.Syntax.Lexer
  Description: NStar's lexer
  Copyright: (c) Mesabloo, 2020
  License: BSD3
  Stability: experimental
-}

module Language.NStar.Syntax.Lexer
( lexFile ) where

import Language.NStar.Syntax.Core (Token(..), LToken)
import Language.NStar.Syntax.Internal (located, megaparsecBundleToDiagnostic)
import Language.NStar.Syntax.Hints (Hintable(..))
import qualified Text.Megaparsec as MP
import qualified Text.Megaparsec.Char as MPC
import qualified Text.Megaparsec.Char.Lexer as MPL
import Data.Text (Text)
import qualified Data.Text as Text (pack, toLower)
import Data.Char (isSpace)
import Data.Function ((&))
import Text.Diagnose (Diagnostic, hint)
import Data.Bifunctor (first)
import Data.Data (Data)
import Data.Typeable (Typeable)

type Lexer a = MP.Parsec LexicalError Text a

-- | The type of possible custom lexical errors, detected during lexing.
data LexicalError
  = UnrecognizedEscapeSequence  -- ^ An escape sequence as not been recognized or is not valid
  deriving (Ord, Eq, Typeable, Data, Read)

instance Show LexicalError where
  show UnrecognizedEscapeSequence = "unrecognized character escape sequence"

instance MP.ShowErrorComponent LexicalError where
  showErrorComponent = show

instance Hintable LexicalError String where
  hints UnrecognizedEscapeSequence =
    [hint "Valid escape sequences are all documented at <https://github.com/nihil-lang/nsc/blob/develop/docs/escape-sequences.md>."]


-- | @space@ only parses any whitespace (not accounting for newlines and vertical tabs) and discards them.
space :: Lexer ()
space = MPL.space spc MP.empty MP.empty
  where spc = () <$ MP.satisfy (and . (<$> [isSpace, (/= '\n'), (/= '\r'), (/= '\v'), (/= '\f')]) . (&))

-- | @lexeme p@ applies @p@ and ignores any space after, if @p@ succeeds. If @p@ fails, @lexeme p@ also fails.
lexeme :: Lexer a -> Lexer a
lexeme = MPL.lexeme space

-- | @symbol str@ tries to parse @str@ exactly, and discards spaces after.
symbol :: Text -> Lexer Text
symbol = MPL.symbol space

-- | Case insensitive variant of 'symbol'.
symbol' :: Text -> Lexer Text
symbol' = MPL.symbol' space

---------------------------------------------------------------------------------------------------------------------------

-- | Runs the program lexer on a given file, and returns either all the tokens identified in the source, or an error.
lexFile :: FilePath                                     -- ^ File name
        -> Text                                         -- ^ File content
        -> Either (Diagnostic [] String Char) [LToken]
lexFile = first (megaparsecBundleToDiagnostic "Lexical error on input") .: MP.runParser lexProgram
  where (.:) = (.) . (.)


-- | Transforms a source code into a non-empty list of tokens (accounting for 'EOF').
lexProgram :: Lexer [LToken]
lexProgram = lexeme (pure ()) *> ((<>) <$> tokens <*> ((: []) <$> eof))
  where
    tokens = MP.many . lexeme $ MP.choice
      [ comment, anySymbol, identifierOrKeyword, literal, eol ]

-- | Parses an end of line and returns 'EOL'.
eol :: Lexer LToken
eol = located (EOL <$ MPC.eol)

-- | Parses an end of file and returns 'EOF'.
--
--   Note that all files end with 'EOF'.
eof :: Lexer LToken
eof = located (EOF <$ MP.eof)

-- | Parses any kind of comment, inline or multiline.
comment :: Lexer LToken
comment = lexeme $ located (inline MP.<|> multiline)
  where
    inline = InlineComment . Text.pack <$> (symbol "#" *> MP.manyTill MP.anySingle (MP.lookAhead (() <$ MPC.eol MP.<|> MP.eof)))
    multiline = MultilineComment . Text.pack <$> (symbol "/*" *> MP.manyTill MP.anySingle (symbol "*/"))

-- | Parses any symbol like @[@ or @,@.
anySymbol :: Lexer LToken
anySymbol = lexeme . located . MP.choice $ sat <$>
  [ (LParen, "("), (LBrace, "{"), (LBracket, "["), (LAngle, "<")
  , (RParen, ")"), (RBrace, "}"), (RBracket, "]"), (RAngle, ">")
  , (Star, "*")
  , (Dollar, "$")
  , (Percent, "%")
  , (Comma, ",")
  , (DoubleColon, "::"), (Colon, ":")
  , (Dot, ".")
  , (Minus, "-") ]
 where
   sat (ret, sym) = ret <$ MPC.string sym

-- | Tries to parse an identifier. If the result appears to be a keyword, it instead returns a keyword.
identifierOrKeyword :: Lexer LToken
identifierOrKeyword = lexeme $ located do
  transform . Text.pack
           <$> ((:) <$> MPC.letterChar
                    <*> MP.many (MPC.alphaNumChar MP.<|> MPC.char '_'))
 where
    transform :: Text -> Token
    transform w@(Text.toLower -> rw) = case rw of
      -- Instructions
      "mov"    -> Mov
      "ret"    -> Ret
      -- Registers
      "rax"    -> Rax
      "rbx"    -> Rbx
      "rcx"    -> Rcx
      "rdx"    -> Rdx
      "rdi"    -> Rdi
      "rsi"    -> Rsi
      "rsp"    -> Rsp
      "rbp"    -> Rbp
      -- Keywords
      "forall" -> Forall
      "sptr"   -> Sptr
      -- Identifier
      _        -> Id w

-- | Parses a literal value (integer or character).
literal :: Lexer LToken
literal = lexeme . located $ MP.choice
  [ Integer <$> prefixed "0b" (Text.pack <$> MP.some binary)
  , Integer <$> prefixed "0x" (Text.pack <$> MP.some hexadecimal)
  , Integer <$> prefixed "0o" (Text.pack <$> MP.some octal)
  , Integer . Text.pack <$> MP.some decimal
  , Char <$> MP.between (MPC.char '\'') (MPC.char '\'') charLiteral ]
  -- FIXME: There is a way to break integer tokens:
  -- When you have a decimal integer beginning with a "0", the "0"
  -- will be stripped off because 'Integer's do not show leading "0"
  -- in its Haskell's 'Show' instance.
  -- The 'Integer' should better take a 'Text', while the 'Read'ing part should
  -- be implemented in the parser.
 where
   charLiteral = escapeChar MP.<|> MP.anySingle
   escapeChar = MPC.char '\\' *> (codes MP.<|> MP.customFailure UnrecognizedEscapeSequence)
   codes = MP.choice
     [ '\a'   <$ MPC.char 'a'   -- Bell
     , '\b'   <$ MPC.char 'b'   -- Backspace
     , '\ESC' <$ MPC.char 'e'   -- Escape character
     , '\f'   <$ MPC.char 'f'   -- Formfeed page break
     , '\n'   <$ MPC.char 'n'   -- Newline (Line feed)
     , '\r'   <$ MPC.char 'r'   -- Carriage return
     , '\t'   <$ MPC.char 't'   -- Horizontal tab
     , '\v'   <$ MPC.char 'v'   -- Vertical tab
     , '\\'   <$ MPC.char '\\'  -- Backslash
     , '\''   <$ MPC.char '\''  -- Apostrophe
     , '"'    <$ MPC.char '"'   -- Double quotation mark
     , '\0'   <$ MPC.char '0'   -- Null character
       -- TODO: add support for unicode escape sequences "\uHHHH" and "\uHHHHHHHH"
     ]

   binary, octal, decimal, hexadecimal :: Lexer Char
   binary      = MP.choice $ MPC.char <$> [ '0', '1' ]
   octal       = MP.choice $ binary : (MPC.char <$> [ '2', '3', '4', '5', '6', '7' ])
   decimal     = MP.choice $ octal : (MPC.char <$> [ '8', '9' ])
   hexadecimal = MP.choice $ decimal : (MPC.char' <$> [ 'a', 'b', 'c', 'd', 'e', 'f' ])
   {-# INLINE binary #-}
   {-# INLINE octal #-}
   {-# INLINE decimal #-}
   {-# INLINE hexadecimal #-}

   prefixed :: (c ~ MP.Tokens Text) => c -> Lexer c -> Lexer c
   prefixed prefix p = (<>) <$> MPC.string' prefix <*> p
   {-# INLINE prefixed #-}
