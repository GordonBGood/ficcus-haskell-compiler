module JsonGen exposing (document)

{-| The deterministic document generator (specification and oracle: ficcus-tools/gen_json.py). Integer arithmetic only. The text is
built as a list of pieces per record, the records are joined at the end.
-}


next : Int -> Int
next s =
    modBy 2147483647 (s * 48271)


alphabet : String
alphabet =
    "abcdefghijklmnopqrstuvwxyz0123456789 _"


escape : Int -> String
escape i =
    case i of
        0 ->
            "\\\""

        1 ->
            "\\\\"

        2 ->
            "\\/"

        3 ->
            "\\n"

        4 ->
            "\\t"

        5 ->
            "\\b"

        6 ->
            "\\u00e9"

        _ ->
            "\\u0041"


genString : Int -> Int -> Int -> List String -> ( Int, List String )
genString lo span seed acc =
    let
        s1 =
            next seed
    in
    genChars (lo + modBy span s1) s1 ("\"" :: acc)


genChars : Int -> Int -> List String -> ( Int, List String )
genChars n seed acc =
    if n == 0 then
        ( seed, "\"" :: acc )

    else
        let
            s =
                next seed

            p =
                modBy 38 (s // 20)

            piece =
                if modBy 20 s < 14 then
                    String.slice p (p + 1) alphabet

                else
                    escape (modBy 8 p)
        in
        genChars (n - 1) s (piece :: acc)


genValue : Int -> Int -> List String -> ( Int, List String )
genValue d seed acc =
    let
        s1 =
            next seed

        k0 =
            modBy 20 s1

        k =
            if d >= 12 && k0 < 10 then
                k0 + 10

            else
                k0
    in
    if k < 5 then
        let
            s2 =
                next s1

            ( s3, acc3 ) =
                genItems (modBy 5 s2) 0 d s2 ("[" :: acc)
        in
        ( s3, "]" :: acc3 )

    else if k < 10 then
        let
            s2 =
                next s1

            ( s3, acc3 ) =
                genMembers (modBy 5 s2) 0 d s2 ("{" :: acc)
        in
        ( s3, "}" :: acc3 )

    else if k == 10 then
        ( s1, "null" :: acc )

    else if k == 11 then
        ( s1, "true" :: acc )

    else if k == 12 then
        ( s1, "false" :: acc )

    else if k < 16 then
        let
            s2 =
                next s1

            s3 =
                next s2

            acc1 =
                if modBy 4 s2 == 0 then
                    "-" :: acc

                else
                    acc
        in
        ( s3, String.fromInt (modBy 1000000 s3) :: acc1 )

    else if k < 18 then
        let
            s2 =
                next s1

            s3 =
                next s2

            s4 =
                next s3

            s5 =
                next s4

            acc1 =
                if modBy 4 s2 == 0 then
                    "-" :: acc

                else
                    acc

            text =
                String.fromInt (modBy 10000 s3) ++ "." ++ String.padLeft 6 '0' (String.fromInt (modBy 64 s4 * 15625))
        in
        if modBy 8 s5 == 0 then
            let
                s6 =
                    next s5

                suffix =
                    case modBy 3 s6 of
                        0 ->
                            "e1"

                        1 ->
                            "E+2"

                        _ ->
                            "e0"
            in
            ( s6, suffix :: text :: acc1 )

        else
            ( s5, text :: acc1 )

    else
        genString 0 12 s1 acc


genItems : Int -> Int -> Int -> Int -> List String -> ( Int, List String )
genItems n i d seed acc =
    if i == n then
        ( seed, acc )

    else
        let
            ( s, acc2 ) =
                genValue (d + 1) seed (separator i acc)
        in
        genItems n (i + 1) d s acc2


genMembers : Int -> Int -> Int -> Int -> List String -> ( Int, List String )
genMembers n i d seed acc =
    if i == n then
        ( seed, acc )

    else
        let
            ( s1, acc1 ) =
                genString 1 8 seed (separator i acc)

            ( s2, acc2 ) =
                genValue (d + 1) s1 (": " :: acc1)
        in
        genMembers n (i + 1) d s2 acc2


separator : Int -> List String -> List String
separator i acc =
    if i > 0 then
        ", " :: acc

    else
        acc


genRecords : Int -> Int -> Int -> List String -> List String
genRecords n i seed records =
    if i == n then
        records

    else
        let
            ( s, acc ) =
                genValue 2 seed []
        in
        genRecords n (i + 1) s (String.concat (List.reverse acc) :: records)


document : Int -> String
document n =
    String.concat [ "[\n", String.join ",\n" (List.reverse (genRecords n 0 12345 [])), "\n]\n" ]
