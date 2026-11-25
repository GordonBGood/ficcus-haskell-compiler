module FicOverlayTime exposing (getZoneName, here)

{-| Ficcus effects E2 step 5: `Time.here` and `Time.getZoneName` on two kernels of the C run time (runtime/fic_sched.h). In Elm the
kernels build the zone themselves (`Elm.Kernel.Time.here` calls `customZone`); here they give an Int and a String and this module builds
the values with elm/time's own functions. As in Elm: `here` is the offset of the local zone NOW (no daylight saving rules), in minutes
east of UTC; `getZoneName` is `Name` of the zone's name when there is one (Intl's timeZone; in C the TZ variable, else the link
/etc/localtime) and otherwise `Offset` of JavaScript's getTimezoneOffset (minutes WEST of UTC). Compiled only into projects that depend
on elm/time (Ficcus.Mono.Overlay); the specializer redirects `Time.here` and `Time.getZoneName` here.
-}

import Task exposing (Task)
import Time


here : Task x Time.Zone
here =
    Task.map (\offset -> Time.customZone offset []) (hereOffset ())


getZoneName : Task x Time.ZoneName
getZoneName =
    zoneName ()
        |> Task.andThen
            (\name ->
                if name == "" then
                    Task.map (\offset -> Time.Offset (negate offset)) (hereOffset ())

                else
                    Task.succeed (Time.Name name)
            )


{-| kernel: the offset of the local zone now, minutes east of UTC
-}
hereOffset : () -> Task x Int
hereOffset u =
    hereOffset u


{-| kernel: the name of the local zone, or ""
-}
zoneName : () -> Task x String
zoneName u =
    zoneName u
