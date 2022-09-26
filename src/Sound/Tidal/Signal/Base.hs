{-# LANGUAGE OverloadedStrings, FlexibleInstances, BangPatterns #-}

-- (c) Alex McLean 2022 and contributors
-- Shared under the terms of the GNU Public License v. 3.0

-- Base representation and instances for Signals, including
-- implementation of Pattern class, plus core definitions of waveforms
-- etc.

module Sound.Tidal.Signal.Base where

import Data.Ratio
import Data.Fixed (mod')
import Data.Maybe (catMaybes, isJust, mapMaybe, fromJust)
import qualified Data.Map.Strict as Map
import Control.Applicative (liftA2)

import Sound.Tidal.Value
import Sound.Tidal.Event
import Sound.Tidal.Types
import Sound.Tidal.Pattern

import Prelude hiding ((<*), (*>))

-- ************************************************************ --
-- Signal

-- | A signal - a function from a timearc to a list of events active
-- during that timearc
-- This was known as a 'Pattern' in the previous version of Tidal. A
-- signal is a function from a timearc (possibly with some other
-- state) to events taking place in that timearc.

-- ************************************************************ --
-- Pattern instance

instance Pattern Signal where
  slowcat = sigSlowcat
  silence = sigSilence
  atom    = sigAtom
  stack   = sigStack
  _fast   = _sigFast
  rev     = sigRev
  _run    = _sigRun
  _scan   = _sigScan
  timeCat = sigTimeCat
  when    = sigWhen
  _ply    = _sigPly
  _patternify f a pat = innerJoin $ (`f` pat) <$> a
  _patternify2 f a b pat = innerJoin $ (\x y -> f x y pat) <$> a <* b
  toSignal = id

-- ************************************************************ --

instance Applicative Signal where
  pure = steady
  (<*>) = app

-- | Apply a pattern of values to a pattern of functions, given a
-- function to merge the 'whole' timearcs
app :: Signal (a -> b) -> Signal a -> Signal b
app patf patv = Signal f
    where f s = concatMap (\ef -> mapMaybe (combine ef) $ query patv s) $ query patf s
          combine ef ev = do new_active <- maybeSect (active ef) (active ev)
                             return $ Event {metadata = metadata ef <> metadata ev,
                                             whole = liftA2 sect (whole ef) (whole ev),
                                             active = new_active,
                                             value = value ef $ value ev
                                            }

-- | Alternative definition of <*>, which takes the wholes from the
-- pattern of functions (unrelated to the <* in Prelude)
(<*) :: Signal (a -> b) -> Signal a -> Signal b
(<*) patf patv = Signal f
  where f s = concatMap (\ef -> mapMaybe (combine ef) $ query patv (s {sArc = wholeOrActive ef})
                        ) $ query patf s
        combine ef ev = do new_active <- maybeSect (active ef) (active ev)
                           return $ Event {metadata = metadata ef <> metadata ev,
                                           whole = whole ef,
                                           active = new_active,
                                           value = value ef $ value ev
                                          }
        
-- | Alternative definition of <*>, which takes the wholes from the
-- pattern of functions (unrelated to the <* in Prelude)
(*>) :: Signal (a -> b) -> Signal a -> Signal b
(*>) patf patv = Signal f
  where f s = concatMap (\ev -> mapMaybe (combine ev) $ query patf (s {sArc = wholeOrActive ev})
                        ) $ query patv s
        combine ev ef = do new_active <- maybeSect (active ef) (active ev)
                           return $ Event {metadata = metadata ef <> metadata ev,
                                           whole = whole ev,
                                           active = new_active,
                                           value = value ef $ value ev
                                          }

infixl 4 <*, *>

-- ************************************************************ --

instance Monoid (Signal a) where
  mempty = silence

instance Semigroup (Signal a) where
  (<>) !p !p' = Signal $ \st -> query p st ++ query p' st

-- ************************************************************ --

instance Monad Signal where
  (>>=) = bind

bind :: Signal a -> (a -> Signal b) -> Signal b
bind = bindWhole (liftA2 sect)

innerBind :: Signal a -> (a -> Signal b) -> Signal b
innerBind = bindWhole (flip const)

innerJoin :: Signal (Signal a) -> Signal a
innerJoin s = innerBind s id

outerBind :: Signal a -> (a -> Signal b) -> Signal b
outerBind = bindWhole (const)

outerJoin :: Signal (Signal a) -> Signal a
outerJoin s = outerBind s id

bindWhole :: (Maybe Arc -> Maybe Arc -> Maybe Arc) -> Signal a -> (a -> Signal b) -> Signal b
bindWhole chooseWhole pv f = Signal $ \state -> concatMap (match state) $ query pv state
  where match state event = map (withWhole event) $ query (f $ value event) (state {sArc = active event})
        withWhole event event' = event' {whole = chooseWhole (whole event) (whole event')}

-- | Like @join@, but cycles of the inner patterns are compressed to fit the
-- timearc of the outer whole (or the original query if it's a continuous pattern?)
-- TODO - what if a continuous pattern contains a discrete one, or vice-versa?
squeezeJoin :: Signal (Signal a) -> Signal a
squeezeJoin pp = pp {query = q}
  where q st = concatMap
          (\e@(Event m w p v) ->
             mapMaybe (munge m w p) $ query (_focusArc (wholeOrActive e) v) st {sArc = p}
          )
          (query pp st)
        munge oMetadata oWhole oPart (Event iMetadata iWhole iPart v) =
          do w' <- (maybeSect <$> oWhole <*> iWhole)
             p' <- maybeSect oPart iPart
             return (Event (iMetadata <> oMetadata) w' p' v)

squeezeBind :: Signal a -> (a -> Signal b) -> Signal b
squeezeBind pat f = squeezeJoin $ fmap f pat

-- Flatterns patterns of patterns, by retriggering/resetting inner patterns at onsets of outer pattern haps

_trigTimeJoin :: (Time -> Time) -> Signal (Signal a) -> Signal a
_trigTimeJoin timeF patOfPats = Signal $ \state -> concatMap (queryInner state) $ query (discreteOnly patOfPats) state
  where queryInner state outerEvent
          = map (\innerEvent ->
                   Event {metadata = metadata innerEvent <> metadata outerEvent,
                          whole = sect <$> whole innerEvent <*> whole outerEvent,
                          active = sect (active innerEvent) (active outerEvent),
                          value = value innerEvent
                         }
                ) $ query (_late (timeF $ (begin $ wholeOrActive outerEvent)) (value outerEvent)) state

trigJoin :: Signal (Signal a) -> Signal a
trigJoin = _trigTimeJoin id

trigZeroJoin :: Signal (Signal a) -> Signal a
trigZeroJoin = _trigTimeJoin cyclePos

-- ************************************************************ --
-- Signals as numbers

noOv :: String -> a
noOv meth = error $ meth ++ ": not supported for signals"

instance Eq (Signal a) where
  (==) = noOv "(==)"

instance Ord a => Ord (Signal a) where
  min = liftA2 min
  max = liftA2 max
  compare = noOv "compare"
  (<=) = noOv "(<=)"

instance Num a => Num (Signal a) where
  negate      = fmap negate
  (+)         = liftA2 (+)
  (*)         = liftA2 (*)
  fromInteger = pure . fromInteger
  abs         = fmap abs
  signum      = fmap signum

instance Enum a => Enum (Signal a) where
  succ           = fmap succ
  pred           = fmap pred
  toEnum         = pure . toEnum
  fromEnum       = noOv "fromEnum"
  enumFrom       = noOv "enumFrom"
  enumFromThen   = noOv "enumFromThen"
  enumFromTo     = noOv "enumFromTo"
  enumFromThenTo = noOv "enumFromThenTo"

instance (Num a, Ord a) => Real (Signal a) where
  toRational = noOv "toRational"

instance (Integral a) => Integral (Signal a) where
  quot          = liftA2 quot
  rem           = liftA2 rem
  div           = liftA2 div
  mod           = liftA2 mod
  toInteger     = noOv "toInteger"
  x `quotRem` y = (x `quot` y, x `rem` y)
  x `divMod`  y = (x `div`  y, x `mod` y)

instance (Fractional a) => Fractional (Signal a) where
  recip        = fmap recip
  fromRational = pure . fromRational

instance (Floating a) => Floating (Signal a) where
  pi    = pure pi
  sqrt  = fmap sqrt
  exp   = fmap exp
  log   = fmap log
  sin   = fmap sin
  cos   = fmap cos
  asin  = fmap asin
  atan  = fmap atan
  acos  = fmap acos
  sinh  = fmap sinh
  cosh  = fmap cosh
  asinh = fmap asinh
  atanh = fmap atanh
  acosh = fmap acosh

instance (RealFrac a) => RealFrac (Signal a) where
  properFraction = noOv "properFraction"
  truncate       = noOv "truncate"
  round          = noOv "round"
  ceiling        = noOv "ceiling"
  floor          = noOv "floor"

instance (RealFloat a) => RealFloat (Signal a) where
  floatRadix     = noOv "floatRadix"
  floatDigits    = noOv "floatDigits"
  floatRange     = noOv "floatRange"
  decodeFloat    = noOv "decodeFloat"
  encodeFloat    = ((.).(.)) pure encodeFloat
  exponent       = noOv "exponent"
  significand    = noOv "significand"
  scaleFloat n   = fmap (scaleFloat n)
  isNaN          = noOv "isNaN"
  isInfinite     = noOv "isInfinite"
  isDenormalized = noOv "isDenormalized"
  isNegativeZero = noOv "isNegativeZero"
  isIEEE         = noOv "isIEEE"
  atan2          = liftA2 atan2

instance Num ValueMap where
  negate      = (applyFIRS negate negate negate id <$>)
  (+)         = Map.unionWith (fNum2 (+) (+))
  (*)         = Map.unionWith (fNum2 (*) (*))
  fromInteger i = Map.singleton "n" $ VI (fromInteger i)
  signum      = (applyFIRS signum signum signum id <$>)
  abs         = (applyFIRS abs abs abs id <$>)

instance Fractional ValueMap where
  recip        = fmap (applyFIRS recip id recip id)
  fromRational r = Map.singleton "speed" $ VF (fromRational r)

-- ************************************************************ --
-- General hacks and utilities

instance Show (a -> b) where
  show _ = "<function>"

filterEvents :: (Event a -> Bool) -> Signal a -> Signal a
filterEvents f pat = Signal $ \state -> filter f $ query pat state

filterValues :: (a -> Bool) -> Signal a -> Signal a
filterValues f = filterEvents (f . value)

filterJusts :: Signal (Maybe a) -> Signal a
filterJusts = fmap fromJust . filterValues isJust

discreteOnly :: Signal a -> Signal a
discreteOnly = filterEvents $ isJust . whole

-- ************************************************************ --
-- Time/event manipulations

queryArc :: Signal a -> Arc -> [Event a]
queryArc sig arc = query sig (State arc Map.empty)

withEventArc :: (Arc -> Arc) -> Signal a -> Signal a
withEventArc arcf sig = Signal f
  where f s = map (\e -> e {active = arcf $ active e,
                            whole = arcf <$> whole e
                           }) $ query sig s

withEventTime :: (Time -> Time) -> Signal a -> Signal a
withEventTime timef sig = Signal f
  where f s = map (\e -> e {active = withArcTime timef $ active e,
                            whole = withArcTime timef <$> whole e
                           }) $ query sig s

withArcTime :: (Time -> Time) -> Arc -> Arc
withArcTime timef (Arc b e) = Arc (timef b) (timef e)

withQuery :: (State -> State) -> Signal a -> Signal a
withQuery statef sig = Signal $ \state -> query sig $ statef state

withQueryArc :: (Arc -> Arc) -> Signal a -> Signal a
withQueryArc arcf = withQuery (\state -> state {sArc = arcf $ sArc state})

withQueryTime :: (Time -> Time) -> Signal a -> Signal a
withQueryTime timef = withQueryArc (withArcTime timef)

-- ************************************************************ --
-- Fundamental signals

sigSilence :: Signal a
sigSilence = Signal (\_ -> [])

-- | Repeat discrete value once per cycle
sigAtom :: a -> Signal a
sigAtom v = Signal $ \state -> map
                               (\arc -> Event {metadata = mempty,
                                                whole = Just $ wholeCycle $ begin arc,
                                                active = arc,
                                                value = v
                                               }
                               )
                               (splitArcs $ sArc state)
  where wholeCycle :: Time -> Arc
        wholeCycle t = Arc (sam t) (nextSam t)

-- | Hold a continuous value
steady :: a -> Signal a
steady v = waveform (const v)

-- ************************************************************ --
-- Waveforms

-- | A continuous pattern as a function from time to values. Takes the
-- midpoint of the given query as the time value.
waveform :: (Time -> a) -> Signal a
waveform timeF = Signal $ \(State (Arc b e) _) -> 
  [Event {metadata = mempty,
          whole = Nothing,
          active = (Arc b e),
          value = timeF $ b+((e - b)/2)
         }
  ]

-- | Sawtooth waveform
saw :: (Fractional a, Real a) => Signal a
saw = waveform $ \t -> mod' (fromRational t) 1

saw2 :: (Fractional a, Real a) => Signal a
saw2 = toBipolar saw

-- | Inverse (descending) sawtooth waveform
isaw :: (Fractional a, Real a) => Signal a
isaw = (1-) <$> saw

isaw2 :: (Fractional a, Real a) => Signal a
isaw2 = toBipolar isaw

-- | Triangular wave
tri :: (Fractional a, Real a) => Signal a
tri = fastAppend saw isaw

tri2 :: (Fractional a, Real a) => Signal a
tri2 = toBipolar tri

-- | Sine waveform
sine :: Fractional a => Signal a
sine = fromBipolar sine2

sine2 :: Fractional a => Signal a
sine2 = waveform $ \t -> realToFrac $ sin ((pi :: Double) * 2 * fromRational t)

-- | Cosine waveform
cosine :: Fractional a => Signal a
cosine = _late 0.25 sine

cosine2 :: Fractional a => Signal a
cosine2 = _late 0.25 sine2

-- | Square wave
square :: Fractional a => Signal a
square = fastAppend (steady 1) (steady 0)

square2 :: Fractional a => Signal a
square2 = fastAppend (steady (-1)) (steady 1)

-- | @envL@ is a 'Signal' of continuous 'Double' values, representing
-- a linear interpolation between 0 and 1 during the first cycle, then
-- staying constant at 1 for all following cycles. Possibly only
-- useful if you're using something like the retrig function defined
-- in tidal.el.
envL :: (Fractional a, Ord a) => Signal a
envL = waveform $ \t -> max 0 $ min (fromRational t) 1

envL2 :: (Fractional a, Ord a) => Signal a
envL2 = toBipolar envL

-- | like 'envL' but reversed.
envLR :: (Fractional a, Ord a) => Signal a
envLR = (1-) <$> envL

envLR2 :: (Fractional a, Ord a) => Signal a
envLR2 = toBipolar envLR

-- | 'Equal power' version of 'env', for gain-based transitions
envEq :: (Fractional a, Ord a, Floating a) => Signal a
envEq = waveform $ \t -> sqrt (sin (pi/2 * max 0 (min (fromRational (1-t)) 1)))

envEq2 :: (Fractional a, Ord a, Floating a) => Signal a
envEq2 = toBipolar envEq

-- | Equal power reversed
envEqR :: (Fractional a, Ord a, Floating a) => Signal a
envEqR = waveform $ \t -> sqrt (cos (pi/2 * max 0 (min (fromRational (1-t)) 1)))

envEqR2 :: (Fractional a, Ord a, Floating a) => Signal a
envEqR2 = toBipolar envEqR


time :: Signal Time
time = waveform id

-- ************************************************************ --
-- Signal manipulations

splitQueries :: Signal a -> Signal a
splitQueries pat = Signal $ \state -> (concatMap (\arc -> query pat (state {sArc = arc}))
                                        $ splitArcs $ sArc state)

-- | Concatenate a list of patterns, interleaving cycles.
sigSlowcat :: [Signal a] -> Signal a
sigSlowcat pats = splitQueries $ Signal queryCycle
  where queryCycle state = query (_late (offset $ sArc state) (pat $ sArc state)) state
        pat arc = pats !! (mod (floor $ begin $ arc) n)
        offset arc = (sam $ begin arc) - (sam $ begin arc / (toRational n))
        n = length pats

_sigFast :: Time -> Signal a -> Signal a
_sigFast t pat = withEventTime (/t) $ withQueryTime (*t) $ pat

_fastGap :: Time -> Signal a -> Signal a
_fastGap factor pat = splitQueries $ withEventArc (scale $ 1/factor) $ withQueryArc (scale factor) pat
  where scale factor' arc = Arc b e
          where cycle = sam $ begin arc
                b = cycle + (min 1 $ (begin arc - cycle) * factor)
                e = cycle + (min 1 $ (end   arc - cycle) * factor)

-- | Like @fast@, but only plays one cycle of the original pattern
-- once per cycle, leaving a gap
fastGap :: Signal Time -> Signal a -> Signal a
fastGap = _patternify _fastGap


_compressArc :: Arc -> Signal a -> Signal a
_compressArc (Arc b e) pat | (b > e || b > 1 || e > 1 || b < 0 || e < 0) = silence
                           | otherwise = _late b $ _fastGap (1/(e-b)) pat

-- | Like @fastGap@, but takes the start and duration of the arc to compress the cycle into.
compress :: Signal Time -> Signal Time -> Signal a -> Signal a
compress patStart patDur pat = innerJoin $ (\s d -> _compressArc (Arc s (s+d)) pat) <$> patStart <*> patDur

_focusArc :: Arc -> Signal a -> Signal a
_focusArc (Arc b e) pat = _late (cyclePos b) $ _fast (1/(e-b)) pat

-- | Like @compress@, but doesn't leave a gap and can 'focus' on any arc (not just within a cycle)
focus :: Signal Time -> Signal Time -> Signal a -> Signal a
focus patStart patDur pat = innerJoin $ (\s d -> _focusArc (Arc s (s+d)) pat) <$> patStart <*> patDur

_early :: Time -> Signal a -> Signal a
_early t pat = withEventTime (subtract t) $ withQueryTime (+ t) $ pat

early :: Signal Time -> Signal x -> Signal x
early = _patternify _early

(<~) :: Signal Time -> Signal x -> Signal x
(<~) = early

_late :: Time -> Signal x -> Signal x
_late t = _early (0-t)

late :: Signal Time -> Signal x -> Signal x
late = _patternify _late

(~>) :: Signal Time -> Signal x -> Signal x
(~>) = late

{- | Plays a portion of a pattern, specified by start and duration
The new resulting pattern is played over the time period of the original pattern:

@
d1 $ zoom 0.25 0.75 $ sound "bd*2 hh*3 [sn bd]*2 drum"
@

In the pattern above, `zoom` is used with an arc from 25% to 75%. It is equivalent to this pattern:

@
d1 $ sound "hh*3 [sn bd]*2"
@
-}
zoom :: Signal Time -> Signal Time -> Signal a -> Signal a
zoom patStart patDur pat = innerJoin $ (\s d -> _zoomArc (Arc s (s+d)) pat) <$> patStart <*> patDur

_zoomArc :: Arc -> Signal a -> Signal a
_zoomArc (Arc s e) p = splitQueries $
  withEventArc (mapCycle ((/d) . subtract s)) $ withQueryArc (mapCycle ((+s) . (*d))) p
     where d = e-s

-- compressTo :: (Time,Time) -> Pattern a -> Pattern a
-- compressTo (s,e)      = compressArcTo (Arc s e)

repeatCycles :: Signal Int -> Signal a -> Signal a
repeatCycles = _patternify _repeatCycles

_repeatCycles :: Int -> Signal a -> Signal a
_repeatCycles n p = slowcat $ replicate n p

fastRepeatCycles :: Signal Int -> Signal a -> Signal a
fastRepeatCycles = _patternify _repeatCycles

_fastRepeatCycles :: Int -> Signal a -> Signal a
_fastRepeatCycles n p = fastcat $ replicate n p

sigStack :: [Signal a] -> Signal a
sigStack pats = Signal $ \s -> concatMap (\pat -> query pat s) pats

squash :: Time -> Signal a -> Signal a
squash into pat = splitQueries $ withEventArc ef $ withQueryArc qf pat
  where qf (Arc s e) = Arc (sam s + (min 1 $ (s - sam s) / into)) (sam s + (min 1 $ (e - sam s) / into))
        ef (Arc s e) = Arc (sam s + (s - sam s) * into) (sam s + (e - sam s) * into)

squashTo :: Time -> Time -> Signal a -> Signal a
squashTo b e = _late b . squash (e-b)

sigRev :: Signal a -> Signal a
sigRev pat = splitQueries $ Signal f
  where f state = withArc reflect <$> (query pat $ state {sArc = reflect $ sArc state})
          where cycle = sam $ begin $ sArc state
                next_cycle = nextSam cycle
                reflect (Arc b e) = Arc (cycle + (next_cycle - e)) (cycle + (next_cycle - b))


-- | A pattern of whole numbers from 0 up to (and not including) the
-- given number, in a single cycle.
_sigRun :: (Enum a, Num a) => a -> Signal a
_sigRun n = fastFromList [0 .. n-1]


-- | From @1@ for the first cycle, successively adds a number until it gets up to @n@
_sigScan :: (Enum a, Num a) => a -> Signal a
_sigScan n = slowcat $ map _run [1 .. n]

-- | Similar to @fastCat@, but each pattern is given a relative duration
sigTimeCat :: [(Time, Signal a)] -> Signal a
sigTimeCat tps = stack $ map (\(s,e,p) -> _compressArc (Arc (s/total) (e/total)) p) $ arrange 0 tps
    where total = sum $ map fst tps
          arrange :: Time -> [(Time, Signal a)] -> [(Time, Time, Signal a)]
          arrange _ [] = []
          arrange t ((t',p):tps') = (t,t+t',p) : arrange (t+t') tps'

sigWhen :: Signal Bool -> (Signal b -> Signal b) -> Signal b -> Signal b
sigWhen boolpat f pat = innerJoin $ (\b -> if b then f pat else pat) <$> boolpat


{-|
Only `when` the given test function returns `True` the given pattern
transformation is applied. The test function will be called with the
current cycle as a number.

@
d1 $ whenT ((elem '4').show)
  (striate 4)
  $ sound "hh hc"
@

The above will only apply `striate 4` to the pattern if the current
cycle number contains the number 4. So the fourth cycle will be
striated and the fourteenth and so on. Expect lots of striates after
cycle number 399.
-}
whenT :: (Int -> Bool) -> (Signal a -> Signal a) ->  Signal a -> Signal a
whenT test f p = splitQueries $ p {query = apply}
  where apply st | test (floor $ begin $ sArc st) = query (f p) st
                 | otherwise = query p st


_sigPly :: Time -> Signal a -> Signal a
_sigPly t pat = squeezeJoin $ (_fast t . atom) <$> pat

-- | @segment n p@: 'samples' the signal @p@ at a rate of @n@
-- events per cycle. Useful for turning a continuous pattern into a
-- discrete one.
segment :: Signal Time -> Signal a -> Signal a
segment = _patternify _segment

_segment :: Time -> Signal a -> Signal a
_segment n p = _fast n (atom id) <* p
