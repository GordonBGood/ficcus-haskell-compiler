module FicOverlayRandom exposing (float)

{-| Ficcus: elm/random's `float` with the bounds sorted (decision L32, random#21): `Random.float 100 -100` is `Random.float -100 100`
(Elm's version returns values outside the range). For ordered bounds the stream is Elm's. Public API only. Compiled only into
projects that depend on elm/random (Ficcus.Mono.Overlay); the specializer redirects `Random.float` here, except for the call
below.
-}

import Random exposing (Generator)


float : Float -> Float -> Generator Float
float a b =
    if a > b then
        Random.float b a

    else
        Random.float a b
