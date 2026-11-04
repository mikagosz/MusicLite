#!/bin/bash
# Makes 2-second sample files in many formats and loads each through the built binary
# (MusicLite --probe): checks which engine took it and that the length came out right.
# Usage: Tests/check.sh <path to MusicLite binary>
set -euo pipefail
BIN="$1"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
FAIL=0
make() { ffmpeg -loglevel error -y -f lavfi -i sine=d=2 -ac 2 "$@"; }
# Silence, so a test that does start playing makes no sound.
quiet() { ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=stereo "$@"; }

make "$DIR/a.mp3"; make "$DIR/a.m4a"; make "$DIR/a.wav"; make "$DIR/a.flac"; make "$DIR/a.aiff"
make "$DIR/a.ac3"; make "$DIR/a.opus"; make "$DIR/a.wma"; make "$DIR/a.wv"; make "$DIR/a.mka"
make "$DIR/a.ogg"; make -c:a tta "$DIR/a.tta"; make -c:a pcm_s24le "$DIR/a24.wav"
make -c:a flac -sample_fmt s32 -ar 192000 "$DIR/hires.flac"; make -c:a wavpack -sample_fmt s32p -ar 192000 "$DIR/hires.wv"
ffmpeg -loglevel error -y -f lavfi -i testsrc=d=2:size=160x120 -f lavfi -i sine=d=2 -shortest "$DIR/a.wmv"
printf "to nie jest muzyka %.0s" {1..200} > "$DIR/zepsuty.mp3"
# 40 minutes of WavPack: ffmpeg needs a few seconds for it, long enough to interrupt.
quiet -t 2400 "$DIR/dlugi.wv"; quiet -t 2 "$DIR/cichy.mp3"

expect() {
  local file="$1" engine="$2" out
  if ! out="$("$BIN" --probe "$DIR/$file" 2>&1)"; then echo "  FAIL $file: $out"; FAIL=1; return; fi
  read -r got len <<< "$out"
  if [ "$got" = "$engine" ] && awk "BEGIN{exit !($len > 1.9 && $len < 2.2)}"; then
    echo "  ok   $file ($got, $len s)"
  else
    echo "  FAIL $file: $out (oczekiwane $engine, ~2 s)"; FAIL=1
  fi
}
# PIDs of ffmpeg processes still working on the long sample (by full path, never by name).
decoders() { pgrep -f "ffmpeg.*$DIR/dlugi.wv" || true; }

echo "Odtwarzanie:"
for f in a.mp3 a.m4a a.wav a24.wav a.flac hires.flac a.aiff a.ac3 a.opus; do expect "$f" avfoundation; done
for f in a.wma a.wmv a.wv hires.wv a.mka a.ogg a.tta; do expect "$f" ffmpeg; done
if "$BIN" --probe "$DIR/zepsuty.mp3" > /dev/null 2>&1; then echo "  FAIL zepsuty plik przeszedł"; FAIL=1
else echo "  ok   zepsuty plik daje błąd"; fi

echo "Przerwanie ffmpeg:"
OUT="$("$BIN" --probe-switch "$DIR/dlugi.wv" "$DIR/cichy.mp3" 2>&1 || true)"
read -r got name len <<< "$OUT"
if [ "$got $name" = "avfoundation cichy" ] && awk "BEGIN{exit !($len > 1.9 && $len < 2.2)}" && [ -z "$(decoders)" ]; then
  echo "  ok   zmiana utworu w trakcie dekodowania zatrzymuje ffmpeg i gra nowy"
else
  echo "  FAIL po zmianie utworu: $OUT, ffmpeg: $(decoders | tr '\n' ' ')"; FAIL=1
fi
"$BIN" --probe "$DIR/dlugi.wv" > /dev/null 2>&1 & PROBE=$!
sleep 1
kill -9 "$PROBE"; wait "$PROBE" 2>/dev/null || true
# A killed MusicLite cannot clean up: the next launch removes what it left.
"$BIN" --probe "$DIR/a.mp3" > /dev/null
for PID in $(decoders); do kill "$PID"; done

echo "Korektor:"
# 1 kHz in both channels: the 1K band cut by 12 dB leaves a quarter, balance fully right
# silences the left channel. Played muted.
ffmpeg -loglevel error -y -f lavfi -i sine=f=1000:d=5 -ac 2 "$DIR/k1.m4a"
read -r flat cut left <<< "$("$BIN" --probe-eq "$DIR/k1.m4a" 2>&1 || true)"
if awk "BEGIN{exit !($flat > 0.05 && $cut / $flat > 0.2 && $cut / $flat < 0.32 && $left < 0.001)}" 2>/dev/null; then
  echo "  ok   1 kHz −12 dB: $flat → $cut, balans w prawo: lewy $left"
else
  echo "  FAIL korektor: płasko $flat, −12 dB $cut, balans $left"; FAIL=1
fi

echo "Lista:"
# The file system hands names back decomposed (NFD); the expected strings below are NFC.
nfc() { python3 -c 'import sys,unicodedata;sys.stdout.write(unicodedata.normalize("NFC",sys.stdin.read()))'; }
mkdir "$DIR/album"
for f in "10 Koniec.mp3" "2 Środek.flac" "1 Start.wma" "okladka.jpg" "teledysk.wmv" ".ukryty.mp3"; do : > "$DIR/album/$f"; done
LIST="$("$BIN" --list "$DIR/album/2 Środek.flac" | nfc | tr '\n' '|')"
[ "$LIST" = "> 2 Środek.flac|" ] && echo "  ok   jeden plik to lista z jednym utworem, bez reszty folderu" || { echo "  FAIL $LIST"; FAIL=1; }
LIST="$("$BIN" --list "$DIR/album" | nfc | tr '\n' '|')"
[ "$LIST" = "> 1 Start.wma|2 Środek.flac|10 Koniec.mp3|" ] && echo "  ok   folder: kolejność jak w Finderze, bez obrazków, filmów i ukrytych" || { echo "  FAIL folder: $LIST"; FAIL=1; }
mkdir "$DIR/inny"; : > "$DIR/inny/Obcy.mp3"
LIST="$("$BIN" --list "$DIR/inny/Obcy.mp3" "$DIR/album/10 Koniec.mp3" | nfc | tr '\n' '|')"
[ "$LIST" = "> Obcy.mp3|10 Koniec.mp3|" ] && echo "  ok   pliki z różnych folderów w podanej kolejności" || { echo "  FAIL kilka plików: $LIST"; FAIL=1; }
LIST="$("$BIN" --list "$DIR/album/teledysk.wmv" | nfc | tr '\n' '|')"
[ "$LIST" = "> teledysk.wmv|" ] && echo "  ok   otwarty film trafia na listę" || { echo "  FAIL $LIST"; FAIL=1; }
# A symlink plays the song it points to.
mkdir "$DIR/skroty"; ln -s "$DIR/album/10 Koniec.mp3" "$DIR/skroty/ulubiony.mp3"
LIST="$("$BIN" --list "$DIR/skroty/ulubiony.mp3" | nfc | tr '\n' '|')"
[ "$LIST" = "> 10 Koniec.mp3|" ] && echo "  ok   dowiązanie gra wskazany utwór" || { echo "  FAIL dowiązanie: $LIST"; FAIL=1; }
LEFT="$(ls "${TMPDIR:-/tmp}" | grep -c '^MusicLite-' || true)"
[ "$LEFT" = 0 ] && echo "  ok   brak plików tymczasowych (także po zabitym programie)" || { echo "  FAIL zostało $LEFT plików MusicLite-*"; FAIL=1; }

[ "$FAIL" = 0 ] && echo "Testy: wszystko ok" || { echo "Testy: są błędy"; exit 1; }
