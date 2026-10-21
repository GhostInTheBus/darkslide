#!/bin/bash
# End-to-end smoke test of the installed app. Drives the UI with keystrokes, so run it
# when nobody is typing on this Mac. Usage: Tools/smoke.sh [folder of RAW/JPEG files]
# It copies the folder, opens the copy, rates, rotates, previews, captions, and checks
# the files with exiftool. Exit 0 = pass.
set -u
APP="/Applications/Darkslide.app"; BIN="$APP/Contents/MacOS/Darkslide"; ET="$APP/Contents/Resources/exiftool/exiftool"
SRC="${1:?usage: Tools/smoke.sh <folder of images>}"
TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"; WORK="$TMP/darkslide-smoke/photos"; rm -rf "$TMP/darkslide-smoke"; mkdir -p "$WORK"
ls "$SRC"/* | head -8 | while read f; do cp "$f" "$WORK/"; done
F1=$(ls "$WORK" | head -1); F2=$(ls "$WORK" | sed -n 2p)
fail=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fail=$((fail+1)); }
pkill -x Darkslide 2>/dev/null; sleep 2
defaults write com.ghostinthebus.darkslide lastFolder -string "$WORK"
defaults write com.ghostinthebus.darkslide showNavigator -bool false
open "$APP"; sleep 8
pgrep -x Darkslide >/dev/null && ok "launched" || { bad "did not launch"; exit 1; }
# Safety gate: the app's own log must say it opened the test folder before any key is sent.
LOG="$HOME/Library/Application Support/Darkslide/logs/darkslide.log"
opened=$(grep "\[INFO\] open " "$LOG" 2>/dev/null | tail -1)
if ! echo "$opened" | grep -q "$WORK"; then bad "app did not open the test folder (last open: '${opened#*] }'); refusing to send keys"; pkill -x Darkslide; exit 1; fi
ok "test folder is open; keys are safe to send"
key() { osascript -e 'tell application "Darkslide" to activate' -e 'delay 0.4' -e "tell application \"System Events\" to tell process \"Darkslide\"" -e 'set frontmost to true' -e 'delay 0.2' -e "$1" -e 'end tell' >/dev/null 2>&1; }
key 'key code 115'; sleep 0.5                          # home: first item
key 'keystroke "3"'; sleep 2.5
r=$("$ET" -s -s -s -XMP-xmp:Rating "$WORK/$F1"); [ "$r" = "3" ] && ok "rating 3 written to $F1" || bad "rating: got '$r'"
key 'keystroke "2" using command down'; sleep 2.5
c=$("$ET" -s -s -s -XMP-photomech:ColorClass -n "$WORK/$F1"); [ "$c" = "2" ] && ok "color class 2 written" || bad "class: got '$c'"
o0=$("$ET" -s -s -s -Orientation -n "$WORK/$F1"); key 'keystroke "]" using command down'; sleep 3
o1=$("$ET" -s -s -s -Orientation -n "$WORK/$F1"); [ "$o1" != "$o0" ] && ok "rotate changed orientation $o0 → $o1" || bad "rotate: orientation still '$o1'"
key 'key code 49'; sleep 2.5                           # space: preview
key 'key code 124'; sleep 1; key 'keystroke "5"'; sleep 2.5   # next, 5 stars (advance after rating may move on)
r2=$("$ET" -s -s -s -XMP-xmp:Rating "$WORK/$F2"); [ "$r2" = "5" ] && ok "rating 5 written in preview to $F2" || bad "preview rating: got '$r2'"
key 'key code 53'; sleep 1                              # esc
key 'key code 115'; sleep 0.5; key 'keystroke "i" using command down'; sleep 2.5
key 'keystroke "Smoke test caption"'; sleep 0.5; key 'keystroke "s" using command down'; sleep 3   # ⌘S = Save
cap=$("$ET" -q -if '$XMP-dc:Description =~ /Smoke test caption/' -p '$FileName' "$WORK" 2>/dev/null | head -1); [ -n "$cap" ] && ok "caption saved to $cap" || bad "caption not found in any file"
pgrep -x Darkslide >/dev/null && ok "still running at the end" || bad "crashed during the run"
if grep -q "FATAL" "$LOG" 2>/dev/null; then bad "FATAL in log"; else ok "no FATAL in log"; fi
echo "errors logged during run: $(grep -c "\[ERROR\]" "$LOG" 2>/dev/null)"
pkill -x Darkslide 2>/dev/null; defaults write com.ghostinthebus.darkslide showNavigator -bool true
rm -rf "$TMP/darkslide-smoke"
[ $fail -eq 0 ] && echo "SMOKE PASSED" || echo "SMOKE: $fail FAILED"
exit $fail
