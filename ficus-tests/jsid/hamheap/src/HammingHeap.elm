-- Problem: find the number of Hamming numbers up to a limit inclusive...
-- compile with elm make src/HammingHeap.elm --output=hamheap.js
{-
   The min heap (binary heap) priority queue, LogRep and the Co-Inductive Stream are from
   the Elm entry of the RosettaCode "Hamming numbers" task; the BigInt, Task and Html code
   was dropped and numbers are exact Ints. Two ways to count are given: a plain loop that
   carries the state (as in Hamming.elm) and a consumer of the lazy stream, which allocates
   a closure for every element.
-}


module HammingHeap exposing (main)

import Bitwise exposing (and, shiftRightBy)


limit : number
limit =
    2 ^ 53 - 1



-- an infinite non-empty non-memoizing Co-Inductive Stream (CIS)...


type CIS a
    = CIS a (() -> CIS a)


type PriorityQ comparable v
    = Mt
    | Br comparable v (PriorityQ comparable v) (PriorityQ comparable v)


emptyPQ : PriorityQ comparable v
emptyPQ =
    Mt


peekMinPQ : PriorityQ comparable v -> Maybe ( comparable, v )
peekMinPQ pq =
    case pq of
        Br k v _ _ ->
            Just ( k, v )

        Mt ->
            Nothing


pushPQ : comparable -> v -> PriorityQ comparable v -> PriorityQ comparable v
pushPQ wk wv pq =
    case pq of
        Mt ->
            Br wk wv Mt Mt

        Br vk vv pl pr ->
            if wk <= vk then
                Br wk wv (pushPQ vk vv pr) pl

            else
                Br vk vv (pushPQ wk wv pr) pl


siftdown : comparable -> v -> PriorityQ comparable v -> PriorityQ comparable v -> PriorityQ comparable v
siftdown wk wv pql pqr =
    case pql of
        Mt ->
            Br wk wv Mt Mt

        Br vkl vvl pll prl ->
            case pqr of
                Mt ->
                    if wk <= vkl then
                        Br wk wv pql Mt

                    else
                        Br vkl vvl (Br wk wv Mt Mt) Mt

                Br vkr vvr plr prr ->
                    if wk <= vkl && wk <= vkr then
                        Br wk wv pql pqr

                    else if vkl <= vkr then
                        Br vkl vvl (siftdown wk wv pll prl) pqr

                    else
                        Br vkr vvr pql (siftdown wk wv plr prr)


replaceMinPQ : comparable -> v -> PriorityQ comparable v -> PriorityQ comparable v
replaceMinPQ wk wv pq =
    case pq of
        Mt ->
            Mt

        Br _ _ pl pr ->
            siftdown wk wv pl pr


type alias Trival =
    ( Int, Int, Int )


tvToNum : Trival -> Int
tvToNum ( x2, x3, x5 ) =
    let
        xpnd x m r =
            if x <= 0 then
                r

            else
                xpnd (shiftRightBy 1 x)
                    (m * m)
                    (if and 1 x /= 0 then
                        m * r

                     else
                        r
                    )
    in
    1 |> xpnd x2 2 |> xpnd x3 3 |> xpnd x5 5


type alias LogRep =
    { lr : Float, trv : Trival }


ltLogRep : LogRep -> LogRep -> Bool
ltLogRep lra lrb =
    lra.lr < lrb.lr


oneLogRep : LogRep
oneLogRep =
    { lr = 0.0, trv = ( 0, 0, 0 ) }


lg2_2 : Float
lg2_2 =
    1.0


lg2_3 : Float
lg2_3 =
    1.584962500721156


lg2_5 : Float
lg2_5 =
    2.321928094887362


multLR2 : LogRep -> LogRep
multLR2 lr =
    let
        ( x2, x3, x5 ) =
            lr.trv
    in
    LogRep (lr.lr + lg2_2) ( x2 + 1, x3, x5 )


multLR3 : LogRep -> LogRep
multLR3 lr =
    let
        ( x2, x3, x5 ) =
            lr.trv
    in
    LogRep (lr.lr + lg2_3) ( x2, x3 + 1, x5 )


multLR5 : LogRep -> LogRep
multLR5 lr =
    let
        ( x2, x3, x5 ) =
            lr.trv
    in
    LogRep (lr.lr + lg2_5) ( x2, x3, x5 + 1 )


hammingsLog : () -> CIS Trival
hammingsLog () =
    let
        im235 =
            multLR2 oneLogRep

        im35 =
            multLR3 oneLogRep

        imrg =
            im35

        im5 =
            multLR5 oneLogRep

        next bpq mpq m235 mrg m35 m5 =
            if ltLogRep m235 mrg then
                let
                    omin =
                        case peekMinPQ bpq of
                            Just ( lr, trv ) ->
                                LogRep lr trv

                            Nothing ->
                                m235

                    -- at the beginning!
                    nm235 =
                        multLR2 omin

                    nbpq =
                        replaceMinPQ m235.lr m235.trv bpq
                in
                CIS m235.trv <|
                    \() ->
                        next nbpq mpq nm235 mrg m35 m5

            else if ltLogRep mrg m5 then
                let
                    omin =
                        case peekMinPQ mpq of
                            Just ( lr, trv ) ->
                                LogRep lr trv

                            Nothing ->
                                mrg

                    -- at the beginning!
                    nm35 =
                        multLR3 omin

                    nmrg =
                        if ltLogRep nm35 m5 then
                            nm35

                        else
                            m5

                    nmpq =
                        replaceMinPQ mrg.lr mrg.trv mpq

                    nbpq =
                        pushPQ mrg.lr mrg.trv bpq
                in
                CIS mrg.trv <|
                    \() ->
                        next nbpq nmpq m235 nmrg nm35 m5

            else
                let
                    nm5 =
                        multLR5 m5

                    nmrg =
                        if ltLogRep m35 nm5 then
                            m35

                        else
                            nm5

                    nmpq =
                        pushPQ m5.lr m5.trv mpq

                    nbpq =
                        pushPQ m5.lr m5.trv bpq
                in
                CIS m5.trv <|
                    \() ->
                        next nbpq nmpq m235 nmrg m35 nm5
    in
    CIS ( 0, 0, 0 ) <|
        \() ->
            next emptyPQ emptyPQ im235 imrg im35 im5



-- counting by consuming the stream...


countHamsToCIS : Int -> Int
countHamsToCIS n =
    let
        go (CIS hd tl) cnt =
            if tvToNum hd > n then
                cnt

            else
                go (tl ()) (cnt + 1)
    in
    go (hammingsLog ()) 0



-- counting with the same state carried in a loop (no stream, no closures)...


countHamsTo : Int -> Int
countHamsTo n =
    let
        worker bpq mpq m235 mrg m35 m5 cnt =
            if ltLogRep m235 mrg then
                if tvToNum m235.trv > n then
                    cnt

                else
                    let
                        omin =
                            case peekMinPQ bpq of
                                Just ( lr, trv ) ->
                                    LogRep lr trv

                                Nothing ->
                                    m235
                    in
                    worker (replaceMinPQ m235.lr m235.trv bpq) mpq (multLR2 omin) mrg m35 m5 (cnt + 1)

            else if ltLogRep mrg m5 then
                if tvToNum mrg.trv > n then
                    cnt

                else
                    let
                        omin =
                            case peekMinPQ mpq of
                                Just ( lr, trv ) ->
                                    LogRep lr trv

                                Nothing ->
                                    mrg

                        nm35 =
                            multLR3 omin
                    in
                    worker (pushPQ mrg.lr mrg.trv bpq)
                        (replaceMinPQ mrg.lr mrg.trv mpq)
                        m235
                        (if ltLogRep nm35 m5 then
                            nm35

                         else
                            m5
                        )
                        nm35
                        m5
                        (cnt + 1)

            else if tvToNum m5.trv > n then
                cnt

            else
                let
                    nm5 =
                        multLR5 m5
                in
                worker (pushPQ m5.lr m5.trv bpq)
                    (pushPQ m5.lr m5.trv mpq)
                    m235
                    (if ltLogRep m35 nm5 then
                        m35

                     else
                        nm5
                    )
                    m35
                    nm5
                    (cnt + 1)

        im35 =
            multLR3 oneLogRep
    in
    -- the first element (value 1) is counted by starting at 1
    worker emptyPQ emptyPQ (multLR2 oneLogRep) im35 im35 (multLR5 oneLogRep) 1



-- main is a simple test framework using debug mode for output...


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    answer =
                        "Found "
                            ++ String.fromInt (countHamsTo limit)
                            ++ " Hamming numbers to "
                            ++ String.fromInt limit
                            ++ " inclusive."

                    streamAnswer =
                        "Found "
                            ++ String.fromInt (countHamsToCIS limit)
                            ++ " Hamming numbers to "
                            ++ String.fromInt limit
                            ++ " inclusive (stream)."

                    _ =
                        ficLog answer ()

                    _ =
                        ficLog streamAnswer ()
                in
                ( (), Cmd.none )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


{-| Ficus JS identity fixture: stands in for Debug.log, so that --optimize accepts the program -}
ficLog : String -> a -> a
ficLog text value =
    if String.length text < 0 then
        value

    else
        value
