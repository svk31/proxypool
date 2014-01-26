{-# Language CPP, ForeignFunctionInterface #-}
module ProxyPool.Mining (
    scrypt
  , packBlockHeader
  , merkleRoot
  , fromHex
  , fromWorkNotify
  , unpackIntLE
  , unpackBE
  , packIntLE
  , Work (..)
) where

import ProxyPool.Stratum
import Debug.Trace

import Foreign hiding (unsafePerformIO)
import Foreign.C.Types

import System.IO.Unsafe (unsafePerformIO)

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Base16 as B16

import qualified Data.ByteString.Lazy.Builder as B
import qualified Data.ByteString.Unsafe as B

import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Data.Monoid ((<>), mempty, mconcat)
import Data.Aeson

import qualified Crypto.Hash.SHA256 as S

#include "scrypt.h"

foreign import ccall "scrypt_1024_1_1_256" c_scrypt :: Ptr CChar -> Ptr CChar -> IO ()

data Work
    = Work { w_job             :: T.Text
           , w_prevHash        :: B.ByteString
           , w_coinbase1       :: B.ByteString
           , w_coinbase2       :: B.ByteString
           , w_merkle          :: [B.ByteString]
           , w_blockVersion    :: Word32
           , w_nBit            :: B.ByteString
           } deriving (Show)

fromWorkNotify :: StratumResponse -> Maybe Work
fromWorkNotify wn@(WorkNotify{}) = do
    merkle <- case fromJSON $ Array $ wn_merkle wn of
        Success x -> Just x
        Error _   -> Nothing

    return $ Work (wn_job wn)
                  (unpackBE $ fromHex $ wn_prevHash wn)
                  (fromHex $ wn_coinbase1 wn)
                  (fromHex $ wn_coinbase2 wn)
                  (map fromHex merkle)
                  (fromInteger $ unpackIntBE $ fromHex $ wn_blockVersion wn)
                  (unpackBE $ fromHex $ wn_nBit wn)

fromWorkNotify _ = Nothing

-- | Scrypt proof of work algorithm, expect input to be exactly 80 bytes
scrypt :: B.ByteString -> Integer
scrypt header = unsafePerformIO $ do
    packed <- allocaBytes 32 $ \result -> do
        B.unsafeUseAsCString header $ flip c_scrypt result
        B.packCStringLen (result, 32)

    return . unpackIntLE $ packed

packIntLE :: Integer -> Int -> B.Builder
packIntLE _ 0 = mempty
packIntLE x 1 = B.word8 $ fromInteger x
packIntLE x n = B.word8 (fromInteger $ x .&. 255) <> packIntLE (shiftR x 8) (n - 1)

unpackIntLE :: B.ByteString -> Integer
unpackIntLE = B.foldr' (\byte acc -> acc * 256 + (fromIntegral byte)) 0

unpackIntBE :: B.ByteString -> Integer
unpackIntBE = unpackIntLE . B.reverse

unpackBE :: B.ByteString -> B.ByteString
unpackBE xs = BL.toStrict $ B.toLazyByteString $ mconcat $ take (B.length xs `quot` 4) $ map (B.byteString . B.reverse . B.take 4) $ iterate (B.drop 4) xs

-- | Generates an 80 byte block header
packBlockHeader :: Work -> (Integer, Int) -> (Integer, Int) -> (Integer, Int) -> Int -> Int -> B.ByteString
packBlockHeader work en1 en2 en3 ntime nonce
    = let coinbase = BL.toStrict $ B.toLazyByteString $ B.byteString (w_coinbase1 work) <>
                                                        uncurry packIntLE en1           <>
                                                        uncurry packIntLE en2           <>
                                                        uncurry packIntLE en3           <>
                                                        B.byteString (w_coinbase2 work)

          merkleHash = merkleRoot coinbase $ w_merkle work

      in  BL.toStrict $ B.toLazyByteString $ B.word32LE (w_blockVersion work) <>
                                             B.byteString (w_prevHash work)   <>
                                             B.byteString merkleHash          <>
                                             B.word32LE (fromIntegral ntime)  <>
                                             B.byteString (w_nBit work)       <>
                                             B.word32LE (fromIntegral nonce)

-- | Create merkle root
merkleRoot :: B.ByteString -> [B.ByteString] -> B.ByteString
merkleRoot coinbase branches = foldl (\acc x -> S.hash $ S.hash $ acc <> x) B.empty $ coinbase : branches

-- | Change Text hex string to bytes
fromHex :: T.Text -> B.ByteString
fromHex = fst . B16.decode . T.encodeUtf8

-- | Hashrate, accepts per minute, difficulty conversion functions
ah2d :: Double -> Double -> Double
ah2d a h = (15 * h) / (1073741824 * a)

hd2a :: Double -> Double -> Double
hd2a h d = (15 * h) / (1073741824 * d)

ad2h :: Double -> Double -> Double
ad2h a d = (1073741824 * a * d) / 15
