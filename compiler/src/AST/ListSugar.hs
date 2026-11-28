{-# LANGUAGE QuasiQuotes #-}
module AST.ListSugar
  ( sugarName
  , isSugar
  , displayName
  )
  where


-- Ficus (syntax track E2): `[a]` in a type is the list type `List a`. The parser builds `Src.TType region sugarName [a]`;
-- the name `[]` cannot be written as a type name by a program, so it cannot collide with a user type, and the canonicalizer
-- resolves it to the built-in `List` even when the module declares its own `List` or imports `List` under another name.
-- Messages and docs show it as `List`.


import String (ascii)

import qualified AST.Prim.TypeName as T


sugarName :: T.Name
sugarName =
  T.nameFromString [ascii|[]|]
{-# NOINLINE sugarName #-}


isSugar :: T.Name -> Bool
isSugar name =
  name == sugarName


-- | the name to show to a person
displayName :: T.Name -> T.Name
displayName name =
  if isSugar name then T.list else name
