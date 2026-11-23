app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
}

import cli.Stdout
import cli.Monotonic exposing [now!, since]
import cli.Duration exposing [to_millis]

cLIMIT : U64
cLIMIT = 0

cREPETITIONS : U64
cREPETITIONS = 1

# a growable first-in-first-out queue using a circular buffer...
Queue(a) : { front : U64, back : U64, size : U64, list : List(a) }

initQueue : a -> Queue(a)
initQueue = |x| {
  # start with 16 elements of the initial value...
  { front: 0, back: 1, size: 16, list: List.repeat(x, 16) }
}

peekQueue : Queue(a) -> Try(a, [OutOfBounds])
peekQueue = |q| {
  q.list.get(q.front)
}

pushQueue : Queue(a), a -> Queue(a)
pushQueue = |q, x| {
  nq =
    if (q.back != q.front) q else {
#      svlst = q.list.sublist({ start: q.front, len: q.size - q.front })
#      nlst = q.list.concat(List.repeat(x, q.front)).concat(svlst)
      nlst = q.list.append_sublist(q.list, { start: 0, len: q.size })
      { ..q, size: q.size * 2, front: q.front + q.size, list: nlst }
    }
  newBack = if (nq.back >= nq.size - 1) 0 else (nq.back + 1)
  { ..nq, back: newBack, list: nq.list.set(nq.back, x).ok_or(nq.list) }
}

replaceQueueWith : Queue(a), (a -> a) -> Queue(a)
replaceQueueWith = |q, f| {
  nfront = if (q.front >= q.size - 1) 0 else q.front + 1
  nback = if (q.back >= q.size - 1) 0 else q.back + 1
  fval = match q.list.get(q.front) {
    Ok(v) => v
    Err(_) => crash "Impossible"
  }
  nlst = q.list.set(q.back, f(fval)).ok_or(q.list)
  { ..q, front: nfront, back: nback, list: nlst }
}

# LogRep represents multiples of 2, 3, and 5 that make up a Hamming number...
LogRep : { log2 : F64, twos : U16, threes : U16, fives : U16 }

lg2 : F64
lg2 = 1.0

lg3 : F64
lg3 = 1.584962500721156

lg5 : F64
lg5 = 2.321928094887362

one : LogRep
one = { log2: 0.0, twos: 0, threes: 0, fives: 0 }

mult2 : LogRep -> LogRep
mult2 = |logrep|
  { ..logrep, log2: logrep.log2 + lg2, twos: logrep.twos + 1 }

mult3 : LogRep -> LogRep
mult3 = |logrep|
  { ..logrep, log2: logrep.log2 + lg3, threes: logrep.threes + 1 }

mult5 : LogRep -> LogRep
mult5 = |logrep|
  { ..logrep, log2: logrep.log2 + lg5, fives: logrep.fives + 1 }

# NOT DEBUGGED AS JUST FINAL STEP TO PRODUCE FINAL Str...
BigInt : List(U32)

multBigInt : BigInt, BigInt -> BigInt
multBigInt = |a, b| {
  alen = match a.find_last_index(|e| e != 0) {
    Err(_) => 0
    Ok(ndx) => ndx + 1
  }
  blen = match b.find_last_index(|e| e != 0) {
    Err(_) => 0
    Ok(ndx) => ndx + 1
  }
  mltplr = |j, lst| {
    if (j >= blen) lst else {
      tms = b.get(j).ok_or(0).to_u64()
      mltplcnd = |i, cry, ilst| {
        ndx = i + j
        if (i >= alen) ilst.set(ndx, cry.to_u32_wrap()).ok_or(ilst) else {
          ov = lst.get(ndx).ok_or(0).to_u64()
          m = a.get(i).ok_or(0).to_u64().times_wrap(tms)
          nv = m.bitwise_and(0xFFFFFFFF).plus_wrap(ov).plus_wrap(cry)
          ncry = m.shr_zf_wrap(32).plus_wrap(nv.shr_zf_wrap(32))
          nilst = ilst.set(ndx, nv.to_u32_wrap()).ok_or(ilst)
          mltplcnd(i + 1, ncry, nilst)
        }
      }
      mltplr(j + 1, mltplcnd(0.U64, 0.U64, lst))
    }
  }
  irslt = mltplr(0.U64, List.repeat(0.U32, alen + blen + 1))
  if (irslt.last().ok_or(1) == 0) irslt.drop_last(1) else irslt 
}

quotremBigIntBy10 : BigInt -> ( BigInt, U32 )
quotremBigIntBy10 = |bi| {
  helper = |i, rem, lst| {
    if (i <= 0) {
      match lst.find_last_index(|e| e != 0) {
        Err(_) => ([], rem)
        Ok(ndx) => (lst.drop_last(lst.len() - ndx + 1), rem)
      }
    }
    else {
      ni = i - 1
      ov = lst.get(ni).ok_or(0)
      nvd = ov.div_by(10)
      nrem = ov.minus_wrap(nvd.times_wrap(10))
      helper(ni, nrem, lst.set(ni, nvd).ok_or(lst))
    }
  }
  match bi.find_last_index(|e| e != 0) {
    Err(_) => ([], 0.U32)
    Ok(ndx) => helper(ndx + 1, 0.U32, bi)
  }
}

bigintToStr : BigInt -> Str
bigintToStr = |bi| {
  helper = |ibi, str| {
    if (ibi.len() <= 0) str else {
      ( nibi, dig ) = quotremBigIntBy10(ibi)
      helper(nibi, str.concat(dig.to_str()))
    }
  }
  helper(bi, "")
}

logrepToBigIntString : LogRep -> Str
logrepToBigIntString = |logrep| {
  xpnd = |r, x, m| {
    if (x <= 0) r else {
      xpnd( if (x.bitwise_and(1) > 0) multBigInt(m, r) else r
          , x.shr_zf_wrap(1), multBigInt(m, m) )
    }
  }
  List.repeat(1.U32, 1)
    |> xpnd(logrep.twos, List.repeat(2.U32, 1))
    |> xpnd(logrep.threes, List.repeat(3.U32, 1))
    |> xpnd(logrep.fives, List.repeat(5.U32, 1))
    |> bigintToStr()
}

logrep2Str : LogRep -> Str
logrep2Str = |lr| "{ log2: ${lr.log2.to_str()}, twos: ${lr.twos.to_str()}, threes: ${lr.threes.to_str()}, fives: ${lr.fives.to_str()} }"

nthHamming : U64 -> Str
nthHamming = |n| {
  { # wrapped the `worker` function in a block so the imperative would compile...
  worker = |bigq, smlq, fvs, hd, cnt| {
    if (cnt >= n) logrep2Str(hd) # logrepToBigIntString
    else {
      match peekQueue(bigq) {
        Err(_) => crash "IMPOSSIBLE!!!" # never happens
        Ok(b) =>
          match peekQueue(smlq) {
            Err(_) => crash "IMPOSSIBLE!!!" # never happens
            Ok(s) => {
              min23 = b.log2.min(s.log2)
              if (min23 > fvs.log2)
                  worker( pushQueue(bigq, mult2(fvs))
                        , pushQueue(smlq, mult3(fvs))
                        , mult5(fvs), fvs, cnt + 1 )
              else {
                if (b.log2 < s.log2)
                  worker( replaceQueueWith(bigq, |v| mult2(v))
                        , smlq, fvs, b, cnt + 1 )
                else
                  worker( pushQueue(bigq, mult2(s))
                        , replaceQueueWith(smlq, |v| mult3(v))
                        , fvs, s, cnt + 1 )
              }
            }
          }
      }
    }
  }
  }
#  worker(initQueue(mult2(one)), initQueue(mult3(one)), mult5(one), one, 1)
  # following is imperative equivalent to the above, runs the same speed...
  var $bigq = initQueue(mult2(one))
  var $smlq = initQueue(mult3(one))
  var $fvs = mult5(one)
  var $hd = one
  var $cnt = 1
  while $cnt < n {
    match peekQueue($bigq) {
      Err(_) => crash "IMPOSSIBLE!!!" # never happens
      Ok(b) =>
        match peekQueue($smlq) {
          Err(_) => crash "IMPOSSIBLE!!!" # never happens
          Ok(s) => {
            min23 = b.log2.min(s.log2)
            if (min23 > $fvs.log2) {
              $hd = $fvs
#              $bigq = pushQueue($bigq, mult2($fvs))
              nqb =
                if ($bigq.back != $bigq.front) $bigq else {
                  nlst = $bigq.list.append_sublist($bigq.list, { start: 0, len: $bigq.size })
                  { ..$bigq, size: $bigq.size * 2, front: $bigq.front + $bigq.size, list: nlst }
                }
              newBackb = if (nqb.back >= nqb.size - 1) 0 else (nqb.back + 1)
              $bigq = { ..nqb, back: newBackb, list: nqb.list.set(nqb.back, mult2($fvs)).ok_or(nqb.list) }
#              $smlq = pushQueue($smlq, mult3($fvs))
              nqs =
                if ($smlq.back != $smlq.front) $smlq else {
                  nlst = $smlq.list.append_sublist($smlq.list, { start: 0, len: $smlq.size })
                  { ..$smlq, size: $smlq.size * 2, front: $smlq.front + $smlq.size, list: nlst }
                }
              newBacks = if (nqs.back >= nqs.size - 1) 0 else (nqs.back + 1)
              $smlq = { ..nqs, back: newBacks, list: nqs.list.set(nqs.back, mult3($fvs)).ok_or(nqs.list) }
              $fvs = mult5($fvs)
            }
            else {
              if (b.log2 < s.log2) {
                $hd = b
#                $bigq = replaceQueueWith($bigq, |v| mult2(v))
                nfrnt = if ($bigq.front >= $bigq.size - 1) 0 else $bigq.front + 1
                nbck = if ($bigq.back >= $bigq.size - 1) 0 else $bigq.back + 1
                fv = match $bigq.list.get($bigq.front) {
                  Ok(v) => v
                  Err(_) => crash "Impossible"
                }
                nlst = $bigq.list.set($bigq.back, mult2(fv)).ok_or($bigq.list)
                $bigq = { ..$bigq, front: nfrnt, back: nbck, list: nlst }
              }
              else {
                $hd = s
#                $bigq = pushQueue($bigq, mult2(s))
                nq =
                  if ($bigq.back != $bigq.front) $bigq else {
                    nlst = $bigq.list.append_sublist($bigq.list, { start: 0, len: $bigq.size })
                    { ..$bigq, size: $bigq.size * 2, front: $bigq.front + $bigq.size, list: nlst }
                  }
                newBack = if (nq.back >= nq.size - 1) 0 else (nq.back + 1)
                $bigq = { ..nq, back: newBack, list: nq.list.set(nq.back, mult2(s)).ok_or(nq.list) }
#                $smlq = replaceQueueWith($smlq, |v| mult3(v))
                nfrnt = if ($smlq.front >= $smlq.size - 1) 0 else $smlq.front + 1
                nbck = if ($smlq.back >= $smlq.size - 1) 0 else $smlq.back + 1
                fv = match $smlq.list.get($smlq.front) {
                  Ok(v) => v
                  Err(_) => crash "Impossible"
                }
                nlst = $smlq.list.set($smlq.back, mult3(fv)).ok_or($smlq.list)
                $smlq = { ..$smlq, front: nfrnt, back: nbck, list: nlst }
              }
           }
           $cnt = $cnt + 1
         }
       }
    }
  }
  logrep2Str($hd) # logrepToBigIntString
}

main! = |args| {
  # an external input so that compiler doesn't optimize away the run time;
  # this defaults to zero when no argument is passed, which is fine...
  inp = match args.get(1) {
    Ok(arg_os_str) => U64.from_str(arg_os_str.display()).ok_or(0.U64)
    Err(_) => 0
  }
  start = now!()
  answr = nthHamming(cLIMIT + inp)
  stop = now!()
  elpsd = stop.since(start).to_millis()
  
  Stdout.line!("The ${(cLIMIT + inp).to_str()}th Hamming number is ${answr.to_str()} in ${elpsd.to_str()} milliseconds for ${cREPETITIONS.to_str()} repetitions.")
}
