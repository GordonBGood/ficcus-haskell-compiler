{-# LANGUAGE OverloadedStrings #-}
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
module Parse.Members
  ( whereBlock
  , noWhere
  , mangleMember
  )
  where


import qualified AST.Members as Members
import qualified AST.Source as Src
import qualified AST.Prim.TypeName as T
import qualified Parse.Keyword as Keyword
import qualified Parse.Space as Space
import Parse.Primitives (Parser, oneOfWithFallback, specialize, withIndent, getPosition)
import qualified Parse.Primitives as P
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Syntax as E



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
            do  (first, firstEnd) <- specialize E.CT_Member member
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
          (m, newEnd) <- specialize E.CT_Member member
          chompMembers member (m : revMembers) newEnd
    ]
    (reverse revMembers, end)



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
  A.At region (Src.Value (A.At nameRegion (Members.mangle tipe name)) args body maybeType)
