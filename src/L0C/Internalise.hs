{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
-- |
--
-- This module implements a transformation on L0 programs that
-- simplifies various uses of tuples.  The input program must be
-- uniquely named (as by the "L0.Renamer" module).  The output program
-- has the following properties:
--
--    * No function accepts a tuple as an argument.  Instead, they
--    have been rewritten to accept the tuple components explicitly.
--
--    * All tuples are flat - that is, their components are not
--    tuples.  @(t1,(t2,t3))@ is rewritten to @(t1,t2,t3)@.
--
--    * There are no arrays of tuples.  @[(t1,t2)]@ is rewritten to
--    @([t1], [t2])@.
--
--    * All bindings are full.  @let v = (x,y)@ is rewritten to @let
--    (v_1, v_2) = (x,y)@.  Combined with the first property, this
--    implies that no variable is ever bound to a tuple.
--
--    * SOACs are converted to their tuple versions.
--
module L0C.Internalise
  ( internaliseProg
  , internaliseType
  , internaliseValue
  )
  where

import Control.Applicative
import Control.Monad.State  hiding (mapM)
import Control.Monad.Reader hiding (mapM)

import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet      as HS
import Data.Maybe
import Data.List
import Data.Loc
import Data.Traversable (mapM)

import L0C.ExternalRep as E
import L0C.InternalRep as I
import L0C.MonadFreshNames
import L0C.Tools

import L0C.Internalise.Monad
import L0C.Internalise.AccurateSizes
import L0C.Internalise.TypesValues
import L0C.Internalise.Bindings
import L0C.Internalise.Lambdas
import L0C.Substitute

import Prelude hiding (mapM)

-- | Convert a program in external L0 to a program in internal L0.
internaliseProg :: E.Prog -> I.Prog
internaliseProg prog =
  I.Prog $ runInternaliseM prog $ liftM concat $
           mapM (split <=< internaliseFun) $ E.progFunctions prog
  where split fun = do (sfun@(_,srettype,_,_,_), vfun) <- splitFunction fun
                       if null srettype
                       then return [vfun]
                       else return [sfun,vfun]

internaliseFun :: E.FunDec -> InternaliseM I.FunDec
internaliseFun (fname,rettype,params,body,loc) =
  bindingParams params $ \params' -> do
    body' <- internaliseBody body
    return (fname, rettype', params', body', loc)
  where rettype' = map I.toDecl $ typeSizes $ internaliseType rettype

internaliseIdent :: E.Ident -> InternaliseM I.Ident
internaliseIdent (E.Ident name tp loc) =
  case internaliseType tp of
    [I.Basic tp'] -> return $ I.Ident name (I.Basic tp') loc
    _             -> fail "L0C.Internalise.internaliseIdent: asked to internalise non-basic-typed ident."

internaliseCerts :: E.Certificates -> I.Certificates
internaliseCerts = map internaliseCert
  where internaliseCert (E.Ident name _ loc) =
          I.Ident name (I.Basic I.Cert) loc

internaliseBody :: E.Exp -> InternaliseM Body
internaliseBody e = insertBindings $ do
  ses <- letTupExp "norm" =<< internaliseExp e
  return $ I.Result [] (subExpsWithShapes $ map I.Var ses) $ srclocOf e

internaliseBodyNoCertReturn :: E.Exp -> InternaliseM Body
internaliseBodyNoCertReturn e = insertBindings $ do
  (c,ses) <- tupToIdentList e
  return $ I.Result (maybeToList c) (subExpsWithShapes $ map I.Var ses) $ srclocOf e

internaliseExp :: E.Exp -> InternaliseM I.Exp

internaliseExp (E.Var var) = do
  subst <- asks $ HM.lookup (E.identName var) . envSubsts
  case subst of
    Nothing     -> I.SubExp <$> I.Var <$> internaliseIdent var
    Just substs ->
      return $ I.TupLit (concatMap insertSubst substs) $ srclocOf var
  where insertSubst (DirectSubst v)   = [I.Var v]
        insertSubst (ArraySubst c ks) = c : map I.Var ks

internaliseExp (E.Index cs var csidx idxs loc) = do
  idxs' <- letSubExps "i" =<< mapM internaliseExp idxs
  subst <- asks $ HM.lookup (E.identName var) . envSubsts
  let cs' = internaliseCerts cs
      mkCerts vs = case csidx of
                     Just csidx' -> return $ internaliseCerts csidx'
                     Nothing     -> boundsChecks vs idxs'
  case subst of
    Nothing ->
      fail $ "L0C.Internalise.internaliseExp Index: unknown variable " ++ textual (E.identName var) ++ "."
    Just [ArraySubst c vs] -> do
      c' <- mergeSubExpCerts (c:map I.Var cs')
      csidx' <- mkCerts vs
      let index v = I.Index (certify c' csidx') v idxs' loc
          resultTupLit [] = I.TupLit [] loc
          resultTupLit (a:as)
            | E.arrayRank outtype == 0 = I.TupLit (a:as) loc
            | otherwise                = tuplit c' loc $ a:as
      resultTupLit <$> letSubExps "idx" (map index vs)
    Just [DirectSubst var'] -> do
      csidx' <- mkCerts [var']
      return $ I.Index (cs'++csidx') var' idxs' loc
    Just _ ->
      fail $ "L0C.Internalise.internaliseExp Index: " ++ textual (E.identName var) ++ " is not an aray."

  where outtype = E.stripArray (length idxs) $ E.identType var

internaliseExp (E.TupLit es loc) = do
  ks <- tupsToIdentList es
  return $ I.TupLit (map I.Var $ combCertExps ks) loc

internaliseExp (E.ArrayLit [] et loc) =
  case internaliseType et of
    [et'] -> return $ arrayLit et'
    ets -> do
      es <- letSubExps "arr_elem" $ map arrayLit ets
      return $ I.TupLit (given loc : es) loc
  where arrayLit et' = I.ArrayLit [] (et' `annotateArrayShape` ([],loc)) loc

internaliseExp (E.ArrayLit es rowtype loc) = do
  aes <- tupsToIdentList es
  let (cs, es'@((e':_):_)) = unzip aes --- XXX, ugh.
      Shape rowshape = arrayShape $ I.identType e'
  case internaliseType rowtype of
    [et] -> do
      ses <- letSubExps "arr_elem" $ map (tuplit Nothing loc . map I.Var) es'
      return $ I.ArrayLit ses
               (et `setArrayShape` Shape (intlit (length es) : drop 1 rowshape))
               loc
    ets   -> do
      let arraylit ks et = I.ArrayLit (map I.Var ks)
                           (et `setArrayShape` Shape (intlit (length es) : rowshape))
                           loc
      c <- mergeCerts $ catMaybes cs
      tuplit c loc <$> letSubExps "arr_elem" (zipWith arraylit (transpose es') ets)
  where intlit x = I.Constant (I.BasicVal $ I.IntVal x) loc

internaliseExp (E.Apply fname args _ loc)
  | "trace" <- nameToString fname = do
  args' <- tupsToIdentList $ map fst args
  let args'' = concatMap tag args'
  return $ I.Apply fname args'' (map (subExpType . fst) args'')  loc
  where tag (_,vs) = [ (I.Var v, I.Observe) | v <- vs ]

internaliseExp (E.Apply fname args rettype loc) = do
  args' <- tupsToIdentList $ map fst args
  args'' <- concat <$> mapM flatten args'
  result_shape <- resultShape args''
  let valueRettype' = addTypeShapes valueRettype result_shape
  return $ I.Apply fname args'' valueRettype' loc
  where (shapeRettype, valueRettype) = splitType $ typeSizes $ internaliseType rettype
        shapeFname = shapeFunctionName fname

        flatten (c,vs) = do
          vs' <- liftM concat $ forM vs $ \v -> do
                   let shape = subExpShape $ I.Var v
                   -- Diet wrong, but will be fixed by type-checker.
                   return [ (arg, I.Observe) | arg <- I.Var v : shape ]
          return $ (case c of Just c' -> [(I.Var c', I.Observe)]
                              Nothing -> []) ++ vs'

        resultShape args''
          | []      <- shapeRettype = return []
          | otherwise               =
            liftM (map I.Var) $
            letTupExp "fun_shape" $
            I.Apply shapeFname [ (arg, I.Observe) | (arg, _) <- args'']
            shapeRettype loc

internaliseExp (E.LetPat pat e body loc) = do
  (c,ks) <- tupToIdentList e
  bindingPattern pat (certOrGiven loc c) (map I.identType ks) $ \pat' -> do
    letBind pat' $ I.TupLit (map I.Var ks) loc
    internaliseExp body

internaliseExp (E.DoLoop mergepat mergeexp i bound loopbody letbody loc) = do
  bound' <- letSubExp "bound" =<< internaliseExp bound
  (c,mergevs) <- tupToIdentList mergeexp
  i' <- internaliseIdent i
  bindingPattern mergepat (certOrGiven loc c) (map I.identType mergevs) $ \mergepat' -> do
    loopbody' <- internaliseBodyNoCertReturn loopbody
    let (_, valuebody) = splitBody loopbody'
    loopBind (zip mergepat' $ map I.Var mergevs) i' bound' valuebody
    internaliseExp letbody

internaliseExp (E.LetWith cs name src idxcs idxs ve body loc) = do
  idxs' <- letSubExps "idx" =<< mapM internaliseExp idxs
  (c1,srcs) <- tupToIdentList (E.Var src)
  (c2,vnames) <- tupToIdentList ve
  let cs' = internaliseCerts cs
  idxcs' <- case idxcs of
              Just idxcs' -> return $ internaliseCerts idxcs'
              Nothing     -> boundsChecks srcs idxs'
  dsts <- map fst <$> mapM (newVar loc "letwith_dst" . I.identType) srcs
  c <- mergeCerts (catMaybes [c1,c2]++cs')
  let comb (dname, sname, vname) =
        letWithBind (cs'++idxcs') dname sname idxs' $ I.Var vname
  mapM_ comb $ zip3 dsts srcs vnames
  bindingPattern (E.Id name) (certOrGiven loc c)
                             (map I.identType dsts) $ \pat' -> do
    letBind pat' $ I.TupLit (map I.Var dsts) loc
    internaliseExp body

internaliseExp (E.Replicate ne ve loc) = do
  ne' <- letSubExp "n" =<< internaliseExp ne
  (_,ves) <- tupToIdentList ve -- XXX - ignoring certificate?
  case ves of
    [ve'] -> return $ I.Replicate ne' (I.Var ve') loc
    _ -> do reps <- letSubExps "v" [I.Replicate ne' (I.Var ve') loc | ve' <- ves ]
            return $ I.TupLit (given loc : reps) loc

internaliseExp (E.Size _ i e loc) = do
  (_,ks) <- tupToIdentList e
  -- XXX: Throwing away certificates?
  case ks of
    (k:_) -> return $ I.SubExp $ I.arraySize i $ I.identType k
    _     -> return $ I.SubExp (I.Constant (I.BasicVal $ I.IntVal 0) loc) -- Will this ever happen?

internaliseExp (E.Unzip e _ _) = do
  (_,ks) <- tupToIdentList e
  return $ I.TupLit (map I.Var ks) $ srclocOf e

internaliseExp (E.Zip es loc) = do
  lst <- tupsToIdentList (map fst es)
  let (cs1, names) = splitCertExps lst
  case names of
    [] -> return $ I.TupLit [] loc
    _ -> do
      let namevs = map I.Var names
          rows e = arraySize 0 $ I.subExpType e
          ass e1 e2 = do cmp <- letSubExp "zip_cmp" $ I.BinOp I.Equal (rows e1) (rows e2) (I.Basic I.Bool) loc
                         pure $ I.Assert cmp loc
      cs2 <- letExps "zip_assert" =<< zipWithM ass namevs (drop 1 namevs)
      c <- mergeCerts (cs1++cs2)
      return $ tuplit c loc namevs

internaliseExp (E.Iota e loc) = do
  e' <- letSubExp "n" =<< internaliseExp e
  return $ I.Iota e' loc

internaliseExp (E.Transpose cs k n e loc) =
  internaliseOperation "transpose" cs e loc $ \cs' v ->
    let rank = I.arrayRank $ I.identType v
        perm = transposeIndex k n [0..rank-1]
    in  I.Rearrange cs' perm (I.Var v) loc

internaliseExp (E.Rearrange cs perm e loc) =
  internaliseOperation "rearrange" cs e loc $ \cs' v ->
    I.Rearrange cs' perm (I.Var v) loc

internaliseExp (E.Reshape cs shape e loc) = do
  shape' <- letSubExps "shape" =<< mapM internaliseExp shape
  internaliseOperation "reshape" cs e loc $ \cs' v ->
    I.Reshape cs' shape' (I.Var v) loc

internaliseExp (E.Split cs nexp arrexp loc) = do
  let cs' = internaliseCerts cs
  nexp' <- letSubExp "n" =<< internaliseExp nexp
  uncurry (internalise cs' nexp') =<< tupToIdentList arrexp
  where internalise _ _ _ [] = -- Will this ever happen?
          fail "L0C.Internalise.internaliseExp Split: Empty array"
        internalise cs' nexp' _ [arr] =
          return $ I.Split cs' nexp' (I.Var arr) loc
        internalise cs' nexp' c arrs = do
          cs'' <- mergeCerts (certify c cs')
          partnames <- forM (map I.identType arrs) $ \et -> do
                         a <- fst <$> newVar loc "split_a" et
                         b <- fst <$> newVar loc "split_b" et
                         return (a, b)
          let cert = maybe (given loc) I.Var cs''
              combsplit arr (a,b) =
                letBind [a,b] $ I.Split (certify c []) nexp' (I.Var arr) loc
              els = (cert : map (I.Var . fst) partnames) ++
                    (cert : map (I.Var . snd) partnames)
          zipWithM_ combsplit arrs partnames
          return $ I.TupLit els loc

internaliseExp (E.Concat cs x y loc) = do
  (xc,xs) <- tupToIdentList x
  (yc,ys) <- tupToIdentList y
  let cs' = internaliseCerts cs
  internalise cs' xc xs yc ys
  where internalise cs' _ [x'] _ [y'] =
         return $ I.Concat cs' (I.Var x') (I.Var y') loc
        internalise cs' xc xs yc ys = do
          let certs = catMaybes [xc,yc]++cs'
              conc xarr yarr =
                I.Concat certs (I.Var xarr) (I.Var yarr) loc
          c' <- mergeCerts certs
          concs <- letSubExps "concat" $ zipWith conc xs ys
          return $ tuplit c' loc concs

internaliseExp (E.Map lam arr _ loc) = do
  (c,arrs) <- tupToIdentList arr
  let cs = certify c []
  se <- conjoinCerts cs loc
  (cs2, lam') <- internaliseMapLambda internaliseBody se lam $ map I.Var arrs
  certifySOAC se $ I.Map (cs++cs2) lam' (map I.Var arrs) loc

internaliseExp (E.Reduce lam ne arr _ loc) = do
  (c1,arrs) <- tupToIdentList arr
  (c2,nes) <- tupToIdentList ne
  let cs = catMaybes [c1,c2]
  se <- conjoinCerts cs loc
  (cs2, lam') <- internaliseFoldLambda internaliseBody se lam
                 (map I.identType nes) (map I.identType arrs)
  return $ I.Reduce (cs++cs2) lam' (zip (map I.Var nes) (map I.Var arrs)) loc

internaliseExp (E.Scan lam ne arr _ loc) = do
  (c1,arrs) <- tupToIdentList arr
  (c2,nes) <- tupToIdentList ne
  let cs = catMaybes [c1,c2]
  se <- conjoinCerts cs loc
  (cs2, lam') <- internaliseFoldLambda internaliseBody se lam
                 (map I.identType nes) (map I.identType arrs)
  return $ I.Scan (cs++cs2) lam' (zip (map I.Var nes) (map I.Var arrs)) loc


internaliseExp (E.Filter lam arr _ loc) = do
  (c,arrs) <- tupToIdentList arr
  let cs = catMaybes [c]
  se <- conjoinCerts cs loc
  (outer_shape, lam') <- internaliseFilterLambda internaliseBody se lam $
                         map I.Var arrs
  certifySOAC se $ I.Filter cs lam' (map I.Var arrs) outer_shape loc

internaliseExp (E.Redomap lam1 lam2 ne arrs _ loc) = do
  (c1,arrs') <- tupToIdentList arrs
  (c2,nes) <- tupToIdentList ne
  let cs = catMaybes [c1,c2]
  se <- conjoinCerts cs loc
  (cs2,lam1') <- internaliseFoldLambda internaliseBody se lam1
                 (map I.identType nes) (map I.identType nes)
  (cs3,lam2') <- internaliseFoldLambda internaliseBody se lam2
                 (map I.identType nes) (map I.identType arrs')
  return $ I.Redomap (cs++cs2++cs3) lam1' lam2'
           (map I.Var nes) (map I.Var arrs') loc

-- The "interesting" cases are over, now it's mostly boilerplate.

internaliseExp (E.Literal v loc) =
  return $ case internaliseValue v of
             [v'] -> I.SubExp $ I.Constant v' loc
             vs   -> I.TupLit (map (`I.Constant` loc) vs) loc

internaliseExp (E.If ce te fe t loc) = do
  ce' <- letSubExp "cond" =<< internaliseExp ce
  (shape_te, value_te) <- splitBody <$> internaliseBody te
  (shape_fe, value_fe) <- splitBody <$> internaliseBody fe
  shape_te' <- insertBindings $ copyConsumed shape_te
  shape_fe' <- insertBindings $ copyConsumed shape_fe
  if_shape <- if null $ bodyType shape_te
              then return []
              else letTupExp "if_shape" $
                   I.If ce' shape_te' shape_fe' (bodyType shape_te) loc
  let t' = addTypeShapes (internaliseType t) $ map I.Var if_shape
  return $ I.If ce' value_te value_fe t' loc

internaliseExp (E.BinOp bop xe ye t loc) = do
  xe' <- letSubExp "x" =<< internaliseExp xe
  ye' <- letSubExp "y" =<< internaliseExp ye
  case internaliseType t of
    [I.Basic t'] -> return $ I.BinOp bop xe' ye' (I.Basic t') loc
    _            -> fail "L0C.Internalise.internaliseExp: non-basic type in BinOp."

internaliseExp (E.Not e loc) = do
  e' <- letSubExp "not_arg" =<< internaliseExp e
  return $ I.Not e' loc

internaliseExp (E.Negate e loc) = do
  e' <- letSubExp "negate_arg" =<< internaliseExp e
  return $ I.Negate e' loc

internaliseExp (E.Assert e loc) = do
  e' <- letSubExp "assert_arg" =<< internaliseExp e
  return $ I.Assert e' loc

internaliseExp (E.Copy e loc) = do
  vs <- letTupExp "copy_arg" =<< internaliseExp e
  case vs of
    [v] -> return $ I.Copy (I.Var v) loc
    _    -> do ses <- letSubExps "copy_res" [I.Copy (I.Var v) loc | v <- vs]
               return $ I.TupLit ses loc

internaliseExp (E.Conjoin es loc) = do
  es' <- letSubExps "conjoin_arg" =<< mapM internaliseExp es
  return $ I.Conjoin es' loc
{-
internaliseExp (E.MapT cs fun arrs loc) = do
  arrs' <- letSubExps "map_arg" =<< mapM internaliseExp arrs
  let cs' = internaliseCerts cs
  ce <- conjoinCerts cs' loc
  fun' <- internaliseTupleLambda ce fun
  return $ I.Map cs' fun' arrs' loc

internaliseExp (E.ReduceT cs fun inputs loc) = do
  arrs' <- letSubExps "red_arg" =<< mapM internaliseExp arrs
  accs' <- letSubExps "red_acc" =<< mapM internaliseExp accs
  let cs' = internaliseCerts cs
  ce <- conjoinCerts cs' loc
  fun' <- internaliseTupleLambda ce fun
  return $ I.Reduce cs' fun' (zip accs' arrs') loc
  where (accs, arrs) = unzip inputs

internaliseExp (E.ScanT cs fun inputs loc) = do
  arrs' <- letSubExps "scan_arg" =<< mapM internaliseExp arrs
  accs' <- letSubExps "scan_acc" =<< mapM internaliseExp accs
  let cs' = internaliseCerts cs
  ce <- conjoinCerts cs' loc
  fun' <- internaliseTupleLambda ce fun
  return $ I.Scan cs' fun' (zip accs' arrs') loc
  where (accs, arrs) = unzip inputs

internaliseExp (E.FilterT cs fun arrs loc) = do
  arrs' <- letSubExps "filter_arg" =<< mapM internaliseExp arrs
  let cs' = internaliseCerts cs
  ce <- conjoinCerts cs' loc
  fun' <- internaliseTupleLambda ce fun
  return $ I.Filter cs' fun' arrs' loc

internaliseExp (E.RedomapT cs fun1 fun2 accs arrs loc) = do
  accs' <- letSubExps "redomap_acc" =<< mapM internaliseExp accs
  arrs' <- letSubExps "redomap_arg" =<< mapM internaliseExp arrs
  let cs' = internaliseCerts cs
  ce <- conjoinCerts cs' loc
  fun1' <- internaliseTupleLambda ce fun1
  fun2' <- internaliseTupleLambda ce fun2
  return $ I.Redomap cs' fun1' fun2' accs' arrs' loc

-}

tupToIdentList :: E.Exp -> InternaliseM (Maybe I.Ident, [I.Ident])
tupToIdentList e = do
  e' <- internaliseExp e
  case I.typeOf e' of
    [] -> return (Nothing, [])
    [t] -> case e' of
                  I.SubExp (I.Var var) ->
                    return (Nothing, [var]) -- Just to avoid too many spurious bindings.
                  _ -> do
                    name <- fst <$> newVar loc "val" t
                    letBind [name] e'
                    return (Nothing, [name])
    ts -> do
      vs <- mapM identForType ts
      letBind vs e'
      let (certvs, valuevs) = partition ((==I.Basic Cert) . I.identType) vs
      case certvs of
        []  -> return (Nothing, vs)
        [c] -> return (Just c, valuevs)
        _   -> do
          cert <- letExp "tup_arr_cert_comb" $ I.Conjoin (map I.Var certvs) loc
          return (Just cert, valuevs)
  where loc = srclocOf e
        identForType (I.Basic Cert) = newIdent "tup_arr_cert" (I.Basic Cert) loc
        identForType t              = newIdent "tup_arr_elem" t loc

tupsToIdentList :: [E.Exp] -> InternaliseM [(Maybe I.Ident, [I.Ident])]
tupsToIdentList = tupsToIdentList' []
  where tupsToIdentList' acc [] = return acc
        tupsToIdentList' acc (e:es) = do
          (c,e') <- tupToIdentList e
          tupsToIdentList' (acc++[(c,e')]) es

conjoinCerts :: I.Certificates -> SrcLoc -> InternaliseM I.Ident
conjoinCerts cs loc =
  letExp "cert" $ I.Conjoin (map I.Var cs) loc

splitCertExps :: [(Maybe I.Ident, [I.Ident])] -> ([I.Ident], [I.Ident])
splitCertExps l = (mapMaybe fst l,
                   concatMap snd l)

combCertExps :: [(Maybe I.Ident, [I.Ident])] -> [I.Ident]
combCertExps = concatMap $ \(cert, ks) -> maybeToList cert ++ ks

mergeCerts :: [I.Ident] -> InternaliseM (Maybe I.Ident)
mergeCerts = mergeSubExpCerts . map I.Var

mergeSubExpCerts :: [I.SubExp] -> InternaliseM (Maybe I.Ident)
mergeSubExpCerts [] = return Nothing
mergeSubExpCerts [I.Var c] = return $ Just c
mergeSubExpCerts (c:cs) = do
  cert <- fst <$> newVar loc "comb_cert" (I.Basic I.Cert)
  letBind [cert] $ I.Conjoin (c:cs) loc
  return $ Just cert
  where loc = srclocOf c

internaliseOperation :: String
                     -> E.Certificates
                     -> E.Exp
                     -> SrcLoc
                     -> (I.Certificates -> I.Ident -> I.Exp)
                     -> InternaliseM I.Exp
internaliseOperation s cs e loc op = do
  (c,vs) <- tupToIdentList e
  let cs' = internaliseCerts cs
  cs'' <- mergeCerts (certify c cs')
  es <- letSubExps s $ map (op (certify c cs')) vs
  return $ tuplit cs'' loc es

tuplit :: Maybe I.Ident -> SrcLoc -> [I.SubExp] -> I.Exp
tuplit _ _ [e] = SubExp e
tuplit Nothing loc es = I.TupLit (given loc:es) loc
tuplit (Just c) loc es = I.TupLit (I.Var c:es) loc

-- Name suggested by Spectrum.
given :: SrcLoc -> SubExp
given = I.Constant $ I.BasicVal I.Checked

certify :: Maybe I.Ident -> I.Certificates -> I.Certificates
certify k cs = maybeToList k ++ cs

certOrGiven :: SrcLoc -> Maybe I.Ident -> SubExp
certOrGiven loc = maybe (given loc) I.Var

certifySOAC :: I.Ident -> I.Exp -> InternaliseM I.Exp
certifySOAC c e =
  case I.typeOf e of
    [_] -> return e
    ts  -> do (ks,vs) <- unzip <$> mapM (newVar loc "soac") ts
              letBind ks e
              return $ I.TupLit (I.Var c:vs) loc
  where loc = srclocOf e

boundsChecks :: [I.Ident] -> [I.SubExp] -> InternaliseM I.Certificates
boundsChecks []    _  = return []
boundsChecks (v:_) es = zipWithM (boundsCheck v) [0..] es

boundsCheck :: I.Ident -> Int -> I.SubExp -> InternaliseM I.Ident
boundsCheck v i e = do
  let size  = arraySize i $ I.identType v
      check = eBinOp LogAnd (pure lowerBound) (pure upperBound) bool loc
      lowerBound = I.BinOp Leq (I.Constant (I.BasicVal $ IntVal 0) loc)
                               size bool loc
      upperBound = I.BinOp Less e size bool loc
  letExp "bounds_check" =<< eAssert check
  where bool = I.Basic Bool
        loc = srclocOf e

copyConsumed :: I.Body -> InternaliseM I.Body
copyConsumed e
  | consumed <- HS.toList $ freeUniqueInBody e,
    not (null consumed) = do
      copies <- copyVariables consumed
      let substs = HM.fromList $ zip (map I.identName consumed)
                                     (map I.identName copies)
      return $ substituteNames substs e
  | otherwise = return e
  where copyVariables = mapM copyVariable
        copyVariable v =
          letExp (textual (baseName $ I.identName v) ++ "_copy") $
                 I.Copy (I.Var v) loc
          where loc = srclocOf v

        freeUniqueInBody = HS.filter (I.unique . I.identType) . I.freeInBody
