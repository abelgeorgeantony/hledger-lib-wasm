module System.Console.Terminal.Size
  ( Window (..),
    size,
    hSize,
    fdSize,
  )
where

import System.IO (Handle)

data Window a = Window
  { height :: !a,
    width :: !a
  }
  deriving (Eq, Show, Read)

size :: Integral n => IO (Maybe (Window n))
size = pure Nothing

hSize :: Integral n => Handle -> IO (Maybe (Window n))
hSize _ = pure Nothing

fdSize :: Integral n => Int -> IO (Maybe (Window n))
fdSize _ = pure Nothing
