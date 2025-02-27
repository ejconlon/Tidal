-- (c) Alex McLean, Aravind Mohandas and contributors 2022
-- Shared under the terms of the GNU Public License v3.0

module Sound.Tidal.Pattern where

import           Sound.Tidal.Types

-- ************************************************************ --
-- Pattern class

class (Functor p, Applicative p, Monad p) => Pattern p where
  toSignal :: p a -> Signal a
  slowcat :: [p a] -> p a
  fastcat :: [p a] -> p a
  fastcat pats = _fast (toRational $ length pats) $ slowcat pats
  _fast :: Time -> p a -> p a
  silence :: p a
  atom :: a -> p a
  stack :: [p a] -> p a
  -- patternify the first parameter
  _patternify :: (a -> p b -> p c) -> (p a -> p b -> p c)
  -- patternify the first two parameters
  _patternify_p_p :: (a -> b -> p c -> p d) -> (p a -> p b -> p c -> p d)
  -- patternify the first but not the second parameters
  _patternify_p_n :: (a -> b -> p c -> p d) -> (p a -> b -> p c -> p d)
  -- patternify the first three parameters
  _patternify_p_p_p :: (a -> b -> c -> p d -> p e) -> (p a -> p b -> p c -> p d -> p e)
  _appAlign :: (a -> p b -> p c) -> Align (p a) (p b) -> p c
  rev :: p a -> p a
  _ply :: Time -> p a-> p a
  euclid :: p Int -> p Int -> p a -> p a
  _euclid :: Int -> Int -> p a -> p a
  timeCat :: [(Time, p a)] -> p a
  _run :: (Enum a, Num a) => a -> p a
  _scan :: (Enum a, Num a) => a -> p a
  -- every :: p Int -> (p b -> p b) -> p b -> p b
  when :: p Bool -> (p b -> p b) -> p b -> p b
  -- listToPat :: [a] -> p a
  _iter :: Int -> p a -> p a
  _iterBack :: Int -> p a -> p a
  collect :: Eq a => p a -> p [a]
  uncollect :: p [a] -> p a
  _pressBy :: Time -> p a -> p a

-- ************************************************************ --
-- Alignment

(<#), (#>), (|#), (#|), (|#|), (!#), (!!#) :: a -> b -> Align a b
(<#) = Align Squeeze
(#>) = Align SqueezeOut
(|#) = Align CycleIn
(#|) = Align CycleOut
(|#|) = Align CycleMix
(!#) = Align Trig
(!!#) = Align TrigZero

infixl 4 <#, #>, |#, #|, |#|, !#, !!#

_opA :: Pattern p => (a -> b -> c) -> Align (p a) (p b) -> p c
_opA op = _appAlign $ fmap . op

addA :: Num a => Pattern p => Align (p a) (p a) -> p a
addA = _opA (+)

subA :: Num a => Pattern p => Align (p a) (p a) -> p a
subA = _opA (-)

mulA :: Num a => Pattern p => Align (p a) (p a) -> p a
mulA = _opA (*)

divA :: Fractional a => Pattern p => Align (p a) (p a) -> p a
divA = _opA (/)

modA :: Integral a => Pattern p => Align (p a) (p a) -> p a
modA = _opA mod

powA :: Integral a => Pattern p => Align (p a) (p a) -> p a
powA = _opA (^)

powfA :: Floating a => Pattern p => Align (p a) (p a) -> p a
powfA = _opA (**)

-- ************************************************************ --
-- Other functions common to Signals and Sequences

overlay :: Pattern p => p x -> p x -> p x
overlay a b = stack [a, b]

superimpose :: Pattern p => (p x -> p x) -> p x -> p x
superimpose p pat = overlay pat (p pat)

_slow :: Pattern p => Time -> p x -> p x
_slow 0 _   = silence
_slow t pat = _fast (1/t) pat

slow :: Pattern p => p Time -> p x -> p x
slow = _patternify _slow

slowA :: Pattern p => Align (p Time) (p x) -> p x
slowA = _appAlign _slow

-- | An alias for @slow@
sparsity :: Pattern p => p Time -> p x -> p x
sparsity = slow

fast :: Pattern p => p Time -> p x -> p x
fast = _patternify _fast

fastA :: Pattern p => Align (p Time) (p x) -> p x
fastA = _appAlign _fast

-- | An alias for @fast@
density :: Pattern p => p Time -> p x -> p x
density = fast

_inside :: Pattern p => Time -> (p a -> p b) -> p a -> p b
_inside n f p = _fast n $ f (_slow n p)

inside :: Pattern p => p Time -> (p a -> p b) -> p a -> p b
inside = _patternify_p_n _inside

_outside :: Pattern p => Time -> (p a1 -> p a) -> p a1 -> p a
_outside n = _inside (1/n)

outside :: Pattern p => p Time -> (p a1 -> p a) -> p a1 -> p a
outside = _patternify_p_n _outside

-- | Alias for @fastcat@
fastCat :: Pattern p => [p a] -> p a
fastCat = fastcat

-- | Alias for @slowcat@
cat :: Pattern p => [p a] -> p a
cat = slowcat

fastAppend :: Pattern p => p x -> p x -> p x
fastAppend a b = fastcat [a,b]

slowAppend :: Pattern p => p x -> p x -> p x
slowAppend a b = slowcat [a,b]

append :: Pattern p => p x -> p x -> p x
append = slowAppend

-- | Converts from a range from 0 to 1, to a range from -1 to 1
toBipolar :: (Pattern p, Fractional x) => p x -> p x
toBipolar pat = fmap (\v -> (v*2)-1) pat

-- | Converts from a range from -1 to 1, to a range from 0 to 1
fromBipolar :: (Pattern p, Fractional x) => p x -> p x
fromBipolar pat = fmap (\v -> (v+1)/2) pat

-- | Turns a list of values into a pattern
fromList :: Pattern t => [a] -> t a
fromList = slowcat . map pure

-- | Turns a list of values into a pattern
fastFromList :: Pattern t => [a] -> t a
fastFromList = fastcat . map pure

-- | 'fromMaybes; is similar to 'fromList', but allows values to
-- be optional using the 'Maybe' type, so that 'Nothing' results in
-- gaps in the pattern.
fromMaybes :: Pattern t => [Maybe a] -> t a
fromMaybes = fastcat . map f
  where f Nothing  = silence
        f (Just x) = pure x

run :: (Pattern t, Enum a, Num a) => t a -> t a
run = (>>= _run)

scan :: (Pattern t, Enum a, Num a) => t a -> t a
scan = (>>= _run)

_firstOf :: Pattern t => Int -> (t a -> t a) -> t a -> t a
_firstOf n f pat | n <= 0 = silence
                 | otherwise = when (fromList
                                     (True : replicate (n - 1) False)
                                    ) f pat

firstOf :: Pattern t => t Int -> (t a -> t a) -> t a -> t a
firstOf = _patternify_p_n _firstOf

_lastOf :: Pattern t => Int -> (t a -> t a) -> t a -> t a
_lastOf n f pat | n <= 0 = silence
                | otherwise = when (fromList
                                    (replicate (n - 1) False ++ [True])
                                   ) f pat

lastOf :: Pattern t => t Int -> (t a -> t a) -> t a -> t a
lastOf = _patternify_p_n _lastOf

_every :: Pattern t => Int -> (t a -> t a) -> t a -> t a
_every = _lastOf

every :: Pattern t => t Int -> (t a -> t a) -> t a -> t a
every = lastOf

-- | @foldEvery ns f p@ applies the function @f@ to @p@, and is applied for
-- each cycle in @ns@.
foldEvery :: Pattern t => [Int] -> (t a -> t a) -> t a -> t a
foldEvery ns f p = foldr (`_every` f) p ns

{- | `range` will take a pattern which goes from 0 to 1 (like `sine`), and range it to a different range - between the first and second arguments. In the below example, `range 1 1.5` shifts the range of `sine1` from 0 - 1 to 1 - 1.5.

@
d1 $ jux (iter 4) $ sound "arpy arpy:2*2"
  |+ speed (slow 4 $ range 1 1.5 sine1)
@
-}
range :: (Pattern t, Num a) => t a -> t a -> t a -> t a
range = _patternify_p_p _range

_range :: (Functor f, Num b) => b -> b -> f b -> f b
_range from to p = (+ from) . (* (to-from)) <$> p

iter :: Pattern p => p Int -> p a -> p a
iter = _patternify _iter

iterA :: Pattern p => Align (p Int) (p a) -> p a
iterA = _appAlign _iter

iterBack :: Pattern p => p Int -> p a -> p a
iterBack = _patternify _iterBack

iterBackA :: Pattern p => Align (p Int) (p a) -> p a
iterBackA = _appAlign _iterBack

-- | @palindrome p@ applies @rev@ to @p@ every other cycle, so that
-- the pattern alternates between forwards and backwards.
palindrome :: Pattern p => p a -> p a
palindrome p = slowAppend p (rev p)

-- | Repeats each event @n@ times within its arc
ply :: Pattern p => p Time -> p a -> p a
ply = _patternify _ply

plyA :: Pattern p => Align (p Time) (p a) -> p a
plyA = _appAlign _ply

-- | Syncopates a rhythm, shifting each event halfway into its arc (aka timespan), e.g. @"a b [c d] e"@ becomes the equivalent of @"[~ a] [~ b] [[~ c] [~ d]] [~ e]"@
press :: Pattern p => p a -> p a
press = _pressBy 0.5

-- | Like @press@, but allows you to specify the amount in which each event is shifted. @pressBy 0.5@ is the same as @press@, while @pressBy (1/3)@ shifts each event by a third of its arc.
pressBy :: Pattern p => p Time -> p a -> p a
pressBy = _patternify _pressBy

-- ************************************************************ --

