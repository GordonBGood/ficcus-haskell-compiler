module Vault exposing (Vault, new, peek)


type Vault = Vault Int
    where
        secret : Vault -> Int
        secret (Vault n) = n


new : Int -> Vault
new =
    Vault


peek : Vault -> Int
peek v =
    Vault.secret v
