-- Problem: find the number of prime numbers up to a limit inclusive...
-- compile with elm make src/SievePQ.elm --output=prmpq.js
{-
   Hamming numbers are one plus the numbers evenly divisible by 2, 3, or 5
   as 1, 2, 3, 4, 5, 6, 8, 9, 10, 12, 15, 16, 18, 20, 24, 25, 27, 30, 32, 36...
-}


module SievePQ exposing ( main )

cLIMIT : Int
cLIMIT = 6000000

type CIS a = CIS a (() -> CIS a)

{-- }
cis2ListTo : comparable -> CIS comparable -> List comparable
cis2ListTo n cis =
  let loop (CIS hd tl) lst =
        if hd > n then List.reverse lst
        else loop (tl()) (hd :: lst)
  in loop cis []
--}

countCISTo : comparable -> CIS comparable -> Int
countCISTo n cis =
  let loop (CIS hd tl) cnt =
        if hd > n then cnt else loop (tl()) (cnt + 1)
  in loop cis 0

type PriorityQ comparable v =
  Mt
  | Br comparable v (PriorityQ comparable v)
                    (PriorityQ comparable v)

emptyPQ : PriorityQ comparable v
emptyPQ = Mt

peekMinPQ : PriorityQ comparable v -> Maybe (comparable, v)
peekMinPQ  pq = case pq of
                  (Br k v _ _) -> Just (k, v)
                  Mt -> Nothing

pushPQ : comparable -> v -> PriorityQ comparable v
           -> PriorityQ comparable v
pushPQ wk wv pq =
  case pq of
    Mt -> Br wk wv Mt Mt
    (Br vk vv pl pr) -> 
      if wk <= vk then Br wk wv (pushPQ vk vv pr) pl
      else Br vk vv (pushPQ wk wv pr) pl

siftdown : comparable -> v -> PriorityQ comparable v
             -> PriorityQ comparable v -> PriorityQ comparable v
siftdown wk wv pql pqr =
  case pql of
    Mt -> Br wk wv Mt Mt
    (Br vkl vvl pll prl) ->
      case pqr of
        Mt -> if wk <= vkl then Br wk wv pql Mt
              else Br vkl vvl (Br wk wv Mt Mt) Mt
        (Br vkr vvr plr prr) ->
          if wk <= vkl && wk <= vkr then Br wk wv pql pqr
          else if vkl <= vkr then Br vkl vvl (siftdown wk wv pll prl) pqr
               else Br vkr vvr pql (siftdown wk wv plr prr)

replaceMinPQ : comparable -> v -> PriorityQ comparable v
                 -> PriorityQ comparable v
replaceMinPQ wk wv pq = case pq of
                          Mt -> Mt
                          (Br _ _ pl pr) -> siftdown wk wv pl pr

primesPQ : () -> CIS Int
primesPQ() =
  let    
    sieve n pq q (CIS bp bptl as bps) =
      if n >= q then
        let adv = bp + bp in let (CIS nbp _ as nbps) = bptl()
        in sieve (n + 2) (pushPQ (q + adv) adv pq) (nbp * nbp) nbps
      else let
             (nxtc, _) = peekMinPQ pq |> Maybe.withDefault (q, 0) -- default when empty
             adjust tpq =
               let (c, adv) = peekMinPQ tpq |> Maybe.withDefault (0, 0)
               in if c > n then tpq
                  else adjust (replaceMinPQ (c + adv) adv tpq)
           in if n >= nxtc then sieve (n + 2) (adjust pq) q bps
              else CIS n <| \ () -> sieve (n + 2) pq q bps
    oddprms() = CIS 3 <| \ () -> sieve 5 emptyPQ 9 <| oddprms()
  in CIS 2 <| \ () -> oddprms()

countPrimesTo : Int -> Int
countPrimesTo n = primesPQ () |> countCISTo n 

main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    answer =
                        "Found "
                            ++ String.fromInt (countPrimesTo cLIMIT)
                            ++ " prime numbers to "
                            ++ String.fromInt cLIMIT
                            ++ " inclusive."

                    _ = Debug.log answer ()
                in
                ( (), Cmd.none )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }