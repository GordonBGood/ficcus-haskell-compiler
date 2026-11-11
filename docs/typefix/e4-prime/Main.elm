module Main exposing (main)

-- E4 prime rule: after a name character, a quote continues the name unless it starts a character literal.
-- `f'a'`, `f'\n'` and `f'\u{0041}'` stay a call of f with a Char, as in Elm 0.19.3.


f : Char -> Int
f ch =
    Char.toCode ch


x' : Int
x' =
    1


y'' : Int
y'' =
    x' + 1


a : Int
a =
    f'a'


b : Int
b =
    f'\n'


c : Int
c =
    f'\u{0041}'


d : Int
d =
    f'\''


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( Debug.log "result" ( ( a, b, c ), ( d, ( x', y'' ) ) ) |> (\_ -> ()), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
