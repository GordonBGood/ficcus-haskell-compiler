{-# LANGUAGE ExtendedLiterals, MagicHash, OverloadedStrings #-}
-- Ficcus (ATTACH, stage A1): the `where` block after a custom type declaration, and the check that
-- a type alias has none.
--
--     type Money = Money Int
--         where
--             zero : Money
--             zero = Money 0
--
--             add : Money -> Money -> Money
--             add (Money a) (Money b) = Money (a + b)
--
-- The members are indented under the type, aligned with each other.
--
-- (A4a) One of the lines of the block may be a `derive` line (AST.Derive):
--
--             derive compare, hash,
--                 toString
module Parse.Members
  ( whereBlock
  , noWhere
  , mangleMember
  , deriveImports
  )
  where


import qualified AST.Derive as Derive
import qualified AST.Members as Members
import qualified AST.Prim.Module as Module
import qualified AST.Prim.Name as N
import qualified AST.Source as Src
import qualified AST.Prim.TypeName as T
import qualified Parse.Keyword as Keyword
import qualified Parse.Space as Space
import Parse.Primitives (Parser, oneOfWithFallback, specialize, withIndent, getPosition, addLocation, word1)
import qualified Parse.Primitives as P
import qualified Parse.Variable as Var
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Syntax as E
import qualified String as S



-- WHERE BLOCK


-- | `end` is where the last variant ended (spaces already chomped).  Returns the members and the
-- end of the block; with no `where` the members are empty and the end is unchanged.
whereBlock
  :: Space.Parser E.Decl (A.Located Src.Value)
  -> A.Position
  -> Space.Parser E.CustomType [A.Located Src.Value]
whereBlock member end =
  oneOfWithFallback
    [ do  Space.checkIndent end E.CT_IndentBar    -- an empty error: only selects the fallback
          Keyword.where_ E.CT_Bar                 -- same
          Space.chompAndCheckIndent E.CT_Space E.CT_IndentMember
          withIndent $
            do  (first, firstEnd) <- item member
                chompMembers member [first] firstEnd
    ]
    ([], end)


chompMembers
  :: Space.Parser E.Decl (A.Located Src.Value)
  -> [A.Located Src.Value]
  -> A.Position
  -> Space.Parser E.CustomType [A.Located Src.Value]
chompMembers member revMembers end =
  oneOfWithFallback
    [ do  Space.checkAligned (\_ cur -> E.CT_IndentBar cur)    -- an empty error: only selects the fallback
          (m, newEnd) <- item member
          chompMembers member (m : revMembers) newEnd
    ]
    (reverse revMembers, end)



-- | a `derive` line or a member
item :: Space.Parser E.Decl (A.Located Src.Value) -> Space.Parser E.CustomType (A.Located Src.Value)
item member =
  orElse deriveLine (specialize E.CT_Member member)


-- | `p`, or `q` when `p` fails without consuming anything (unlike `oneOf`, the error of `q` is kept as it is)
orElse :: Parser x a -> Parser x a -> Parser x a
orElse (P.Parser p) (P.Parser q) =
  P.Parser $ \fpc state cok eok cerr eerr ->
    p fpc state cok eok cerr (\_ _ -> q fpc state cok eok cerr eerr)



-- DERIVE (A4a)


-- | `derive m1, m2, ...`: the keyword, then lower case names separated by commas; a line that goes on is indented
-- more than the members.  The result is the value `$derive` (AST.Derive) whose body is the list of the names.
deriveLine :: Space.Parser E.CustomType (A.Located Src.Value)
deriveLine =
  do  start <- getPosition
      Keyword.derive_ E.CT_Derive                           -- an empty error: not a derive line
      Space.chompAndCheckIndent E.CT_DeriveSpace E.CT_Derive
      (names, end) <- deriveNames []
      noMoreOnTheLine end
      let body = A.at start end (Src.List [ A.At r (Src.Var Src.LowVar n) | A.At r n <- names ])
      return (A.at start end (Src.Value (A.at start end Derive.placeholder) [] body Nothing), end)


deriveNames :: [A.Located N.Name] -> Space.Parser E.CustomType [A.Located N.Name]
deriveNames revNames =
  do  name <- addLocation (Var.lower N.fromAddr E.CT_Derive)
      end <- getPosition
      Space.chomp E.CT_DeriveSpace
      oneOfWithFallback
        [ do  Space.checkIndent end E.CT_Derive                -- an empty error: only selects the fallback
              word1 0x2C#Word8 {-,-} E.CT_Derive               -- same
              Space.chompAndCheckIndent E.CT_DeriveSpace E.CT_Derive
              deriveNames (name : revNames)
        ]
        (reverse (name : revNames), end)


-- | after the last name nothing may follow on the line (or on a line indented more than the members)
noMoreOnTheLine :: A.Position -> Parser E.CustomType ()
noMoreOnTheLine end =
  oneOfWithFallback
    [ do  Space.checkIndent end E.CT_Derive                    -- an empty error: only selects the fallback
          A.Position cur <- getPosition
          P.Parser $ \_ _ _ _ cerr _ -> cerr cur E.CT_DeriveComma
    ]
    ()



-- ALIAS


-- | a type alias cannot carry members: report a `where` after its body
noWhere :: A.Position -> Parser E.TypeAlias ()
noWhere end =
  oneOfWithFallback
    [ do  Space.checkIndent end E.AliasIndentBody     -- an empty error: only selects the fallback
          A.Position cur <- getPosition
          Keyword.where_ E.AliasEquals                -- same
          P.Parser $ \_ _ _ _ cerr _ -> cerr cur E.AliasWhere
    ]
    ()



-- MANGLING


-- | give a parsed member the global name `Type$$member`
mangleMember :: T.Name -> A.Located Src.Value -> A.Located Src.Value
mangleMember tipe (A.At region (Src.Value (A.At nameRegion name) args body maybeType)) =
  let mangled = if name == Derive.placeholder then Derive.lineName tipe else Members.mangle tipe name in
  A.At region (Src.Value (A.At nameRegion mangled) args body maybeType)



-- IMPORTS OF THE DERIVED MEMBERS (A4a)


-- | a module whose `derive` lines list `encode` or `decoder` imports `Json.Encode` or `Json.Decode` (unaliased, nothing
-- exposed), so that the build orders the modules and the synthesized signatures can name `Json.Encode.Value` and
-- `Json.Decode.Decoder`.  The region of the import is that of the member name (an error about the import points there).
deriveImports :: [A.Located Src.Value] -> [Src.Import] -> [Src.Import]
deriveImports values imports =
  imports ++ dedupe [] needed
  where
    needed =
      [ (modul, region)
      | Just (Derive.Line _ _ members) <- map Derive.lineOf values
      , A.At region member <- members
      , modul <- Derive.needsJson (N.toChars member)
      ]

    present =
      [ Module.toChars name | Src.Import (A.At _ name) Nothing _ <- imports ]

    dedupe seen pending =
      case pending of
        [] -> []
        (modul, region) : rest
          | modul `elem` seen || modul `elem` present -> dedupe seen rest
          | otherwise ->
              Src.Import (A.At region (Module.fromString (S.fromChars modul))) Nothing (Src.Explicit [])
                : dedupe (modul : seen) rest
