{-# LANGUAGE OverloadedStrings #-}

module Sound.Tidal.SignalComposeTest where

import           Test.Microspec
import           TestUtils

import           Prelude             hiding ((*>), (<*))

import           Sound.Tidal.Types
import           Sound.Tidal.Pattern
import           Sound.Tidal.Signal.Base
import           Sound.Tidal.Signal.Compose
import           Sound.Tidal.Signal.ComposeExtra
import           Sound.Tidal.Params (s)

run :: Microspec ()
run =
  describe "Sound.Tidal.Signal.ComposeExtra" $ do
    describe "wedge" $ do
      it "should not freeze tidal if amount is 1" $ do
        compareP (Arc 0 1)
          (wedge (1) (s "ho ho:2 ho:3 hc") (rev $ s "ho ho:2 ho:3 hc"))
          (s "ho ho:2 ho:3 hc")
      it "should not freeze tidal if amount is 0" $ do
        compareP (Arc 0 1)
          (wedge (0) (s "ho ho:2 ho:3 hc") (rev $ s "ho ho:2 ho:3 hc"))
          (rev $ s "ho ho:2 ho:3 hc")
