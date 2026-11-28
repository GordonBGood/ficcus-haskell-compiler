{-# OPTIONS_GHC -Wall -fno-warn-unused-do-bind #-}
{-# LANGUAGE BangPatterns, ExtendedLiterals, MagicHash, OverloadedStrings #-}
-- Ficus (ATTACH, stage A2): the `where` block after a signature.
--
--     sum : List a -> a
--         where
--             a has zero : a
--             a has add as plus : a -> a -> a
--     sum xs = ...
--
-- The result is the signature and the parameters of the hidden-parameter form (AST.Constraints):
-- the type `a -> (a -> a -> a) -> List a -> a` and the patterns `(a$has$zero as zero)`, `(a$has$add as plus)`.
module Parse.Constraints
  ( signatureWhere
  , noLocalWhere
  )
  where



import qualified AST.Constraints as Constraints
import qualified AST.Prim.Name as N
import qualified AST.Prim.TypeVar as T
import qualified AST.Source as Src
import qualified Parse.Keyword as Keyword
import qualified Parse.Space as Space
import qualified Parse.Type as Type
import qualified Parse.Variable as Var
import Parse.Primitives (Parser, oneOfWithFallback, specialize, withIndent, getPosition, word1)
import qualified Parse.Primitives as P
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Syntax as E


data Constraint =
  Constraint A.Region T.Var N.Name (A.Located N.Name) Src.Type


-- | `end` is where the type of the signature ended (spaces already chomped).  Without a `where` the type
-- is returned unchanged, with no patterns.
signatureWhere :: A.Position -> Src.Type -> Parser E.DeclDef (Src.Type, [Src.Pattern])
signatureWhere end tipe =
  oneOfWithFallback
    [ do  Space.checkIndent end E.DeclDefIndentType     -- an empty error: only selects the fallback
          Keyword.where_ E.DeclDefEquals                -- same
          Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefIndentConstraint
          constraints <-
            withIndent $
              do  (first, _) <- constraint
                  chompConstraints [first]
          return (desugar tipe constraints)
    ]
    (tipe, [])


-- | the signature of a `let` definition cannot have constraints (in A2): report a `where` after its type
noLocalWhere :: A.Position -> Parser E.Def ()
noLocalWhere end =
  oneOfWithFallback
    [ do  Space.checkIndent end E.DefIndentType       -- an empty error: only selects the fallback
          A.Position cur <- getPosition
          Keyword.where_ E.DefEquals                  -- same
          P.Parser $ \_ _ _ _ cerr _ -> cerr cur E.DefWhere
    ]
    ()


chompConstraints :: [Constraint] -> Parser E.DeclDef [Constraint]
chompConstraints revConstraints =
  oneOfWithFallback
    [ do  Space.checkAligned (\_ cur -> E.DeclDefNameRepeat cur)     -- an empty error: only selects the fallback
          A.Position cur <- getPosition
          -- the repeated name of the definition can be aligned with the constraints only by mistake: a line
          -- that is not a constraint is reported as one
          (c, _) <- P.Parser $ \fpc state cok eok cerr _ ->
            let P.Parser run = constraint in
            run fpc state cok eok cerr (\_ _ -> cerr cur E.DeclDefConstraint)
          chompConstraints (c : revConstraints)
    ]
    (reverse revConstraints)


-- var has member [as local] : type
constraint :: Space.Parser E.DeclDef Constraint
constraint =
  do  start <- getPosition
      var <- Var.lower T.varFromAddr E.DeclDefConstraint
      Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefConstraint
      A.Position hasCur <- getPosition
      has <- Var.lower N.fromAddr E.DeclDefConstraint
      if N.toChars has /= "has"
        then P.Parser $ \_ _ _ _ cerr _ -> cerr hasCur E.DeclDefConstraint
        else return ()
      Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefConstraint
      memberStart <- getPosition
      member <- Var.lower N.fromAddr E.DeclDefConstraint
      memberEnd <- getPosition
      Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefConstraint
      local <-
        oneOfWithFallback
          [ do  Keyword.as_ E.DeclDefConstraint
                Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefConstraint
                localStart <- getPosition
                name <- Var.lower N.fromAddr E.DeclDefConstraint
                localEnd <- getPosition
                Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefConstraint
                return (A.at localStart localEnd name)
          ]
          (A.at memberStart memberEnd member)
      word1 0x3A#Word8 {-:-} E.DeclDefConstraint
      Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefConstraint
      (tipe, end) <- specialize E.DeclDefType Type.expression
      return (Constraint (regionOf start local) var member local tipe, end)


regionOf :: A.Position -> A.Located a -> A.Region
regionOf (A.Position s) (A.At (A.Region _ e) _) =
  A.Region s e


desugar :: Src.Type -> [Constraint] -> (Src.Type, [Src.Pattern])
desugar tipe@(A.At region _) constraints =
  ( foldr (\(Constraint _ _ _ _ t) result -> A.At region (Src.TLambda t result)) tipe constraints
  , map toPattern constraints
  )
  where
    toPattern (Constraint r var member local _) =
      A.At r (Src.PAlias (A.At r (Src.PVar (Constraints.marker (T.varToChars var) member))) local)
