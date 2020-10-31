{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Data.Elf.Internal.SectionHeader where

import Data.Elf.Types
import Data.Elf.Internal.ToBytes (ToBytes(..))

-- | Section header
data Elf64_Shdr
  = Elf64_Shdr
  { sh_name        :: !Elf64_Word    -- ^ Section name (string table index)
  , sh_type        :: !Elf64_Word    -- ^ Section type
  , sh_flags       :: !Elf64_Xword   -- ^ Section flags
  , sh_addr        :: !Elf64_Addr    -- ^ Section virtual address at execution
  , sh_offset      :: !Elf64_Off     -- ^ Section file offset
  , sh_size        :: !Elf64_Xword   -- ^ Section size in bytes
  , sh_link        :: !Elf64_Word    -- ^ Link to another section
  , sh_info        :: !Elf64_Word    -- ^ Additional section information
  , sh_addralign   :: !Elf64_Xword   -- ^ Section alignment
  , sh_entsize     :: !Elf64_Xword   -- ^ Entry size if section holds table
  }

instance ToBytes Elf64_Shdr where
  toBytes le Elf64_Shdr{..} = mconcat
    [ toBytes le sh_name
    , toBytes le sh_type
    , toBytes le sh_flags
    , toBytes le sh_addr
    , toBytes le sh_offset
    , toBytes le sh_size
    , toBytes le sh_link
    , toBytes le sh_info
    , toBytes le sh_addralign
    , toBytes le sh_entsize
    ]
