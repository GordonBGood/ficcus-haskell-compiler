#!/usr/bin/env python3
"""p1gen.py -- writes cases/<id>/Main.elm for the P1 cases (plain Elm: each is its own twin).  python3 ficcus-tests/p1/p1gen.py"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))

TAIL = '''

logAll : List String -> ()
logAll items =
    List.foldl (\\s acc -> let _ = Debug.log "r" s in acc) () items


main : Program () () ()
main =
    Platform.worker
        { init = \\_ -> let _ = logAll lines in ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
'''

CASES = {
# == and /= : extra fields of several kinds (Int, String, a list, a nested record, a custom type)
"p1-eq": '''
type T r
    = T { r | x : Int }
    | E


type C
    = Red
    | Blue String


a =
    T { x = 1, s = "ab", l = [ 1, 2 ], n = { p = 1.5 }, c = Blue "q" }


lines : List String
lines =
    [ Debug.toString ( a == T { x = 1, s = "ab", l = [ 1, 2 ], n = { p = 1.5 }, c = Blue "q" }, a /= a )
    , Debug.toString ( a == T { x = 1, s = "ab", l = [ 1, 2 ], n = { p = 1.5 }, c = Blue "z" }, a == E )
    , Debug.toString ( a == T { x = 1, s = "ab", l = [ 1 ], n = { p = 1.5 }, c = Blue "q" } )
    , Debug.toString ( a == T { x = 1, s = "ab", l = [ 1, 2 ], n = { p = 2.5 }, c = Blue "q" } )
    , Debug.toString ( a == T { x = 1, s = String.fromInt 7, l = [ 1, 2 ], n = { p = 1.5 }, c = Red } )
    , Debug.toString ( T { x = 1 } == T { x = 1 }, T { x = 1 } == T { x = 2 } )
    ]
''',
# Debug.toString: the extra fields in Elm's order (sorted), nested records, strings
"p1-show": '''
type T r
    = T { r | x : Int }


type W a r
    = W a { r | m : a }


lines : List String
lines =
    [ Debug.toString (T { x = 1, zeta = "z", alpha = 'c', mid = ( 1, "t" ) })
    , Debug.toString (T { x = -3 })
    , Debug.toString [ T { x = 1, y = { q = [ "a" ] } } ]
    , Debug.toString (W "a" { m = "b", k = 2 })
    , Debug.toString (W 1.5 { m = 2.5, b = True, z = Nothing })
    ]
''',
# pattern matching: on the record, on its extra fields, and field destructuring
"p1-match": '''
type T r
    = T { r | x : Int }
    | U Int


sumT : T { y : Int, s : String } -> String
sumT t =
    case t of
        T r ->
            String.fromInt (r.x + r.y) ++ r.s

        U n ->
            String.fromInt n


destr : T { y : Int } -> Int
destr t =
    case t of
        T { x, y } ->
            x * 10 + y

        U _ ->
            0


getX : T { w : String } -> Int
getX t =
    case t of
        T r ->
            r.x

        U n ->
            n


lines : List String
lines =
    [ sumT (T { x = 1, y = 2, s = "!" })
    , sumT (U 9)
    , String.fromInt (destr (T { x = 4, y = 5 }))
    , String.fromInt (getX (T { x = 7, w = "w" }) + getX (U 1))
    ]
''',
# update syntax on the record held in T, then == and toString of the result
"p1-update": '''
type T r
    = T { r | x : Int }


bump : T { name : String } -> T { name : String }
bump (T r) =
    T { r | x = r.x + 1 }


bumpF : T { f : Float } -> T { f : Float }
bumpF (T r) =
    T { r | x = r.x + 1, f = r.f * 2 }


rename : T { name : String } -> T { name : String }
rename (T r) =
    T { r | name = r.name ++ "!" }


a =
    T { x = 1, name = "a" }


lines : List String
lines =
    [ Debug.toString (bump a)
    , Debug.toString (rename (bump a))
    , Debug.toString ( bump a == T { x = 2, name = "a" }, rename a == a )
    , Debug.toString (bumpF (bumpF (T { x = 0, f = 1.5 })))
    ]
''',
# two different rows at the same T in one program, through polymorphic functions
"p1-two-rows": '''
type T r
    = T { r | x : Int }


showT : T r -> String
showT t =
    Debug.toString t


same : T r -> T r -> Bool
same a b =
    a == b


lines : List String
lines =
    [ showT (T { x = 1, y = 2 })
    , showT (T { x = 1, name = "n" })
    , showT (T { x = 1 })
    , Debug.toString ( same (T { x = 1, y = 2 }) (T { x = 1, y = 3 }), same (T { x = 1, name = "n" }) (T { x = 1, name = "n" }) )
    , Debug.toString ( same (T { x = 1, name = "n" }) (T { x = 1, name = "m" }), same (T { x = 1 }) (T { x = 1 }) )
    ]
''',
# the record inside List and Maybe within the custom type, and T inside List / Maybe
"p1-containers": '''
type U r
    = U (List { r | x : Int }) (Maybe { r | x : Int })


type T r
    = T { r | x : Int }


u1 =
    U [ { x = 1, s = "a" }, { x = 2, s = "b" } ] (Just { x = 3, s = "c" })


lines : List String
lines =
    [ Debug.toString u1
    , Debug.toString ( u1 == U [ { x = 1, s = "a" }, { x = 2, s = "b" } ] (Just { x = 3, s = "c" }), u1 == U [ { x = 1, s = "a" }, { x = 2, s = "B" } ] (Just { x = 3, s = "c" }) )
    , Debug.toString ( u1 == U [ { x = 1, s = "a" }, { x = 2, s = "b" } ] Nothing, U [] Nothing == U [ { x = 1 } ] Nothing )
    , Debug.toString [ Just (T { x = 1, y = "q" }), Nothing ]
    , Debug.toString ( [ T { x = 1, y = "q" } ] == [ T { x = 1, y = "r" } ], Just (T { x = 1, y = 2 }) == Just (T { x = 1, y = 2 }) )
    , Debug.toString (List.map (\\(T r) -> T { r | x = r.x * 2 }) [ T { x = 1, y = "a" }, T { x = 2, y = "b" } ])
    ]
''',
# nested: T inside the row of T, a recursive type with a row, and a row that holds another row type
"p1-nested": '''
type T r
    = T { r | x : Int }


type N r
    = N { r | v : Int } (Maybe (N r))


inner =
    T { x = 2, z = "a" }


lines : List String
lines =
    [ Debug.toString (T { x = 1, inner = inner })
    , Debug.toString ( T { x = 1, inner = inner } == T { x = 1, inner = T { x = 2, z = "b" } }, T { x = 1, inner = inner } == T { x = 1, inner = inner } )
    , Debug.toString (N { v = 1, s = "a" } (Just (N { v = 2, s = "b" } Nothing)))
    , Debug.toString ( N { v = 1, s = "a" } (Just (N { v = 2, s = "b" } Nothing)) == N { v = 1, s = "a" } (Just (N { v = 2, s = "c" } Nothing)) )
    , Debug.toString (T { x = 0, t = T { x = 1, t = T { x = 2 } } })
    ]
''',
# pre-existing limit (not P1): field access and update on a row-polymorphic record are refused ("slice 5"), before and after
"p1-poly-row-limit": '''
type T r
    = T { r | x : Int }


getX : T r -> Int
getX (T r) =
    r.x


bump : T r -> T r
bump (T r) =
    T { r | x = r.x + 1 }


lines : List String
lines =
    [ String.fromInt (getX (T { x = 7, w = "w" }) + getX (T { x = 8 }))
    , Debug.toString (bump (T { x = 0, f = 1.5 }))
    ]
''',
}


def main():
    for cid, body in CASES.items():
        d = os.path.join(HERE, "cases", cid)
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "Main.elm"), "w").write("module Main exposing (main)\n\n" + body.strip("\n") + "\n" + TAIL)


if __name__ == "__main__":
    main()
