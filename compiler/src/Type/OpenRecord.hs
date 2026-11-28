{-# OPTIONS_GHC -Wall #-}
-- Ficus (A4bf, the A4b review's F1): `a has compare` and `a has hash` at a record.  Only a closed record has them: an
-- extensible record (`{ r | x : Int }`) may hold more fields through its row, a function among them.  Type.Members.resolve
-- asks `recordRest` about the row of the record and refuses an open one (`errorFor`; Reporting.Error.Type words it).
module Type.OpenRecord
  ( Rest(..)
  , recordRest
  , errorFor
  )
  where


import qualified Data.Map.Strict as Map

import qualified AST.Prim.Name as N
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Type as Error
import Type.Type (Content(..), Descriptor(..), FlatType(..), Variable)
import qualified Type.Type as Type
import qualified Type.UnionFind as UF



-- | the fields of a record type beyond its first layer: closed (an empty record at the end), open (a rigid or other variable:
-- the record is extensible), or not known yet (a flexible variable, which unification may still close)
data Rest
  = Closed [Variable]
  | Open
  | Waits


recordRest :: Variable -> IO Rest
recordRest var =
  do  (Descriptor content _ _ _) <- UF.get var
      case content of
        Structure EmptyRecord1 -> return (Closed [])
        Structure (Record1 fields ext) ->
          do  rest <- recordRest ext
              return $
                case rest of
                  Closed others -> Closed (Map.elems fields ++ others)
                  other -> other
        Alias _ _ _ real -> recordRest real
        FlexVar _ -> return Waits
        _ -> return Open


-- | the NO ATTACHED FUNCTION report of an obligation whose subject is an extensible record (also one whose row stayed
-- flexible to the end, as in an unannotated function: it was never closed); Nothing for any other subject
errorFor :: A.Region -> N.Name -> N.Name -> Variable -> Variable -> IO (Maybe Error.Error)
errorFor region function member subject tipe =
  do  (Descriptor content _ _ _) <- UF.get subject
      open <-
        case content of
          Structure (Record1 _ ext) -> fmap isOpen (recordRest ext)
          Alias _ _ _ real -> isOpenVar real
          _ -> return False
      if not open then return Nothing else
        do  subjectType <- Type.toErrorType subject
            neededType <- Type.toErrorType tipe
            return (Just (Error.NoMember region function subjectType [] True [(member, neededType)]))
  where
    isOpen rest =
      case rest of
        Closed _ -> False
        _ -> True

    isOpenVar var =
      do  (Descriptor content _ _ _) <- UF.get var
          case content of
            Structure (Record1 _ ext) -> fmap isOpen (recordRest ext)
            Alias _ _ _ real -> isOpenVar real
            _ -> return False
