{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import qualified Test.Tasty                       as Tasty
import           Test.Tasty.HUnit                 (testCase, (@=?))
import qualified Test.Tasty.Runners               as Tasty
import           Test.Tasty.SmallCheck            (forAll, testProperty)


import           Control.Monad
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.State.Strict (StateT, evalStateT,
                                                   runStateT)
import qualified Data.Binary                      as Bin
import qualified Data.ByteString                  as B
import qualified Data.ByteString.Lazy             as BL
import           Data.Functor.Identity            (runIdentity)
import           Data.Maybe
import           Lens.Family.State.Strict         (zoom)
import           Pipes
import qualified Pipes.Binary                     as PBin
import qualified Pipes.Parse                      as PP
import qualified Pipes.Prelude                    as P

--------------------------------------------------------------------------------

main :: IO ()
main =  Tasty.defaultMainWithIngredients
  [ Tasty.consoleTestReporter
  , Tasty.listingTests
  ] tests


tests :: Tasty.TestTree
tests = Tasty.testGroup "root"
  [ testFunctorLaws
  , testPipesBinary
  ]


testFunctorLaws :: Tasty.TestTree
testFunctorLaws = Tasty.testGroup "Functor laws (sample test)"
  [ testCase "fmap id Nothing = Nothing" $ do
      fmap id Nothing @=? (Nothing :: Maybe ())
  , testProperty "fmap id = id" $ do
      forAll $ \(x :: [Int]) ->
        fmap id x == id x
  , testCase "fmap (f . g) Nothing = (fmap f . fmap g) Nothing" $ do
      fmap (not . not) Nothing @=? (fmap not . fmap not) (Nothing :: Maybe Bool)
  , testProperty "fmap (f . g) = fmap f . fmap g" $ do
      forAll $ \(x :: [Int]) ->
        fmap (odd . succ) x == (fmap odd . fmap succ) x
  ]

-- Just an arbitrary type that can be generated by SmallCheck.
type FunnyType = (String, (Double, (Int, (Maybe Int, Either Bool Int))))

testPipesBinary :: Tasty.TestTree
testPipesBinary = Tasty.testGroup "pipes-binary"
  [ testProperty "Pipes.Binary.encode ~ Data.Binary.encode" $ do
      forAll $ \(x :: FunnyType) ->
         BL.toStrict (Bin.encode x) == B.concat (P.toList (PBin.encode x))

  , testProperty "Pipes.Binary.decodeL ~ Data.Binary.decode" $ do
      forAll $ \(x :: FunnyType) ->
         let bl = Bin.encode x
             bs = BL.toStrict bl
             o1 = Bin.decodeOrFail bl
             (o2,s2) = fmap (B.concat . P.toList)
                            (runIdentity $ runStateT PBin.decodeL (yield bs))
         in case (o1, o2) of
              (Left (s1,n1,_), Left (PBin.DecodingError n2 _)) ->
                  n1 == n2 && BL.toStrict s1 == s2
              (Right (s1,n1,a1), Right (n2,a2)) ->
                  n1 ==  n2 && BL.toStrict s1 == s2 && a1 == (a2 :: FunnyType)
              _ -> False

  , testProperty "Pipes.Binary.decodeL ~ Pipes.Binary.decode" $ do
      forAll $ \(x :: FunnyType) ->
         let bs = BL.toStrict $ Bin.encode x
             o1 = runIdentity $ evalStateT PBin.decodeL (yield bs)
             o2 = runIdentity $ evalStateT PBin.decode  (yield bs)
         in fmap snd o1 == (o2 :: Either PBin.DecodingError FunnyType)

  , testProperty "Pipes.Binary.decoded zoom" $ do
      forAll $ \amx0 amx1 amx2 amx3 amx4 amx5 amx6 ->
         let xs :: [FunnyType] -- I get more tests cases this way.
             xs = [amx0, amx1, amx2, amx3, amx4, amx5, amx6] >>= maybe [] id
             dec0 :: Monad m => MaybeT (StateT (Producer B.ByteString m a) m) ()
             dec0 = do
               case xs of
                 [] -> do
                   mx0' <- lift $ zoom PBin.decoded PP.draw
                   guard $ isNothing (mx0' :: Maybe FunnyType)
                   rest <- lift $ zoom PBin.decoded PP.drawAll
                   guard $ null (rest :: [FunnyType])
                 (x0:x1:x2:xrest) -> do
                   x0x1' <- lift $ zoom (PBin.decoded . PP.splitAt 2) PP.drawAll
                   guard $ [x0,x1] == x0x1'
                   ex2' <- lift $ PBin.decode
                   guard $ Right x2 == ex2'
                   mx3' <- lift $ zoom PBin.decoded PP.draw
                   case (mx3', xrest) of
                     (Nothing,  []) -> return ()
                     (Just x3', (x3:rest))
                         | x3' == x3 -> do
                               rest' <- lift $ zoom PBin.decoded PP.drawAll
                               guard $ rest == rest'
                     _ -> mzero
                 (x0:xrest) -> do
                   mx0' <- lift $ zoom PBin.decoded PP.draw
                   guard $ Just x0 == mx0'
                   xrest' <- lift $ zoom PBin.decoded PP.drawAll
                   guard $ xrest == xrest'
             p0 = for (each xs) PBin.encode
         in isJust $ runIdentity $ evalStateT (runMaybeT dec0) p0
  ]
