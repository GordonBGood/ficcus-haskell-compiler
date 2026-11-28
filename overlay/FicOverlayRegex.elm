module FicOverlayRegex exposing
    ( compile, valid, groups, exec, found, cap, slice, size, advance
    , fromStringWith, never, contains
    , find, findAtMost, replace, replaceAtMost, split, splitAtMost
    )

{-| Ficus: elm/regex on the kernel of runtime/fic_regex.h (decision L24). Compiled only into projects that depend directly on
elm/regex (Ficus.Mono.Overlay); the specializer redirects every function of the package that is a kernel function in Elm
(`fromStringWith`, `never`, `contains`, `find`, `findAtMost`, `replace`, `replaceAtMost`, `split`, `splitAtMost`) to the function of
the same name here.

The first section only gives the types: those are kernel functions (`author/project:FicOverlayRegex.<name>` in Ficus.Mono.Kernel),
their bodies are never compiled to C. `Regex` is the compiled program, `Caps` the result of one search (see `exec`). Offsets of the
kernel are byte offsets of the UTF-8 text; the `index` of a match is a code point index (L22).

Iteration is the one of JavaScript's `matchAll` (L24): the next search starts where the last match ended, and after an empty match one
code point further. `split` follows `String.prototype.split` (an empty match at the start of a piece, or at the end of the text, is not
a separator), with the limit of Elm (at most that many separators) and without the captured groups (L30).

-}

import Regex exposing (Match, Regex)



-- KERNEL FUNCTIONS (types only)


type Caps
    = Caps


{-| compile the pattern: the flags are 1 (case insensitive) plus 2 (multiline); an invalid pattern gives a Regex for which `valid` is False
-}
compile : Int -> String -> Regex
compile f s =
    compile f s


valid : Regex -> Bool
valid re =
    valid re


{-| the number of capture groups of the pattern
-}
groups : Regex -> Int
groups re =
    groups re


{-| `exec re text from fromCp`: the leftmost match that starts at the byte offset `from` or later (`fromCp` is the code point index of
`from`). The result holds, for a match: 0 start byte, 1 end byte, 2 start code point index, 3 end code point index, then for group
1, 2, ... the start and end byte (-1 and -1: the group did not take part). `found` is False when there is no match.
-}
exec : Regex -> String -> Int -> Int -> Caps
exec re s from fromCp =
    exec re s from fromCp


found : Caps -> Bool
found c =
    found c


cap : Caps -> Int -> Int
cap c i =
    cap c i


{-| the text between two byte offsets (a negative end: to the end of the text)
-}
slice : String -> Int -> Int -> String
slice s a b =
    slice s a b


{-| the byte length of the text
-}
size : String -> Int
size s =
    size s


{-| the byte offset after the code point at the byte offset (one more than the size for the end)
-}
advance : String -> Int -> Int
advance s at =
    advance s at



-- THE FUNCTIONS OF Regex


fromStringWith : Regex.Options -> String -> Maybe Regex
fromStringWith options string =
    let
        re =
            compile
                ((if options.caseInsensitive then
                    1

                  else
                    0
                 )
                    + (if options.multiline then
                        2

                       else
                        0
                      )
                )
                string
    in
    if valid re then
        Just re

    else
        Nothing


{-| a pattern that never matches: `.` must consume a character, `^` then needs the start of the text
-}
never : Regex
never =
    compile 0 ".^"


contains : Regex -> String -> Bool
contains re string =
    found (exec re string 0 0)


{-| the capture groups of a match, in order: the first group is `g`
-}
subs : Caps -> String -> Int -> List (Maybe String) -> List (Maybe String)
subs c string g acc =
    if g < 1 then
        acc

    else
        let
            a =
                cap c (2 + 2 * g)

            sub =
                if a < 0 then
                    Nothing

                else
                    Just (slice string a (cap c (3 + 2 * g)))
        in
        subs c string (g - 1) (sub :: acc)


toMatch : Regex -> String -> Int -> Caps -> Match
toMatch re string number c =
    { match = slice string (cap c 0) (cap c 1)
    , index = cap c 2
    , number = number
    , submatches = subs c string (groups re) []
    }


{-| the position and code point index at which the search continues after a match (one code point further after an empty match)
-}
next : String -> Caps -> ( Int, Int )
next string c =
    if cap c 1 == cap c 0 then
        ( advance string (cap c 1), cap c 3 + 1 )

    else
        ( cap c 1, cap c 3 )


find : Regex -> String -> List Match
find re string =
    findAtMost maxInt re string


maxInt : Int
maxInt =
    9007199254740991


findAtMost : Int -> Regex -> String -> List Match
findAtMost n re string =
    findLoop n 1 re string 0 0 []


findLoop : Int -> Int -> Regex -> String -> Int -> Int -> List Match -> List Match
findLoop limit number re string from fromCp acc =
    if number > limit then
        List.reverse acc

    else
        let
            c =
                exec re string from fromCp
        in
        if found c then
            let
                ( from2, cp2 ) =
                    next string c
            in
            findLoop limit (number + 1) re string from2 cp2 (toMatch re string number c :: acc)

        else
            List.reverse acc


replace : Regex -> (Match -> String) -> String -> String
replace re f string =
    replaceAtMost maxInt re f string


replaceAtMost : Int -> Regex -> (Match -> String) -> String -> String
replaceAtMost n re f string =
    replaceLoop n 1 re f string 0 0 0 []


{-| `prev` is the end of the last match: the text from there to the next match is kept
-}
replaceLoop : Int -> Int -> Regex -> (Match -> String) -> String -> Int -> Int -> Int -> List String -> String
replaceLoop limit number re f string from fromCp prev acc =
    if number > limit then
        String.concat (List.reverse (slice string prev -1 :: acc))

    else
        let
            c =
                exec re string from fromCp
        in
        if found c then
            let
                ( from2, cp2 ) =
                    next string c
            in
            replaceLoop limit
                (number + 1)
                re
                f
                string
                from2
                cp2
                (cap c 1)
                (f (toMatch re string number c) :: slice string prev (cap c 0) :: acc)

        else
            String.concat (List.reverse (slice string prev -1 :: acc))


split : Regex -> String -> List String
split re string =
    splitAtMost maxInt re string


splitAtMost : Int -> Regex -> String -> List String
splitAtMost n re string =
    if n <= 0 then
        [ string ]

    else if size string == 0 then
        -- JavaScript: the empty text splits into no piece when the pattern matches the empty text, else into itself
        if found (exec re string 0 0) then
            []

        else
            [ string ]

    else
        splitLoop n 0 re string 0 0 0 (size string) []


{-| `p` is the start of the current piece, `from` where the search continues. A match that starts at the end of the text is not a
separator, and neither is an empty match at the start of the piece (JavaScript's `split`).
-}
splitLoop : Int -> Int -> Regex -> String -> Int -> Int -> Int -> Int -> List String -> List String
splitLoop limit count re string p from fromCp len acc =
    let
        c =
            exec re string from fromCp
    in
    if not (found c) || cap c 0 >= len then
        List.reverse (slice string p -1 :: acc)

    else if cap c 1 == p then
        splitLoop limit count re string p (advance string (cap c 0)) (cap c 2 + 1) len acc

    else if count + 1 >= limit then
        List.reverse (slice string (cap c 1) -1 :: slice string p (cap c 0) :: acc)

    else
        splitLoop limit (count + 1) re string (cap c 1) (cap c 1) (cap c 3) len (slice string p (cap c 0) :: acc)
