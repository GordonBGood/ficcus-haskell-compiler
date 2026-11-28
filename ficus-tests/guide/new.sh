#!/bin/bash
# new.sh NAME [FILE]: write ficus-tests/guide/NAME/FILE (default Main.fic) from stdin; Main.fic gets the standard `main` appended
# unless it has one (the examples print with Debug.log in `report`)
d=$(dirname "$0")/$1; f=${2:-Main.fic}; mkdir -p "$d/$(dirname "$f")"
cat > "$d/$f"
if [ "$f" = Main.fic ] && ! grep -q '^main :' "$d/$f"; then cat >> "$d/$f" <<'TAIL'


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( report (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
TAIL
fi
