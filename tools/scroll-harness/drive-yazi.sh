#!/usr/bin/env bash
# drive-yazi.sh <ghostty-binary> <log> <title> [extra ghostty flags...]
#
# The one end-to-end check the scroll harness can do today: real keypresses
# into a real application, read back from the detector's own log. input.py
# still cannot drive an application (PROGRESS.md), and `tmux send-keys` never
# reaches Ghostty's input handling, so it never opens the detector at all.
#
# Launches `yazi ~/playground` under the given binary with --scroll-trace,
# focuses it by title through KWin, and only proceeds once ONE probe `j` is
# confirmed to have landed -- by `ya sub hover`, which is yazi saying so, not
# by anything this script assumes. ydotool has no targeting: without that
# probe a burst goes to whatever window has focus.
#
# Then 20 j and 20 k, 450ms apart (outside the detector's 150ms window, so
# each key's log lines are its own), printing the hovered entry and every
# `repaintscroll` / `scroll event` per key. Cleans up by PID only: never
# `pkill -f`, which matches whole command lines and reaches the agent
# session running this.
#
# A/B two builds by running it twice with a different <ghostty-binary>, and
# check the `of RxC` in the output matches -- a window tiled differently
# changes whether the list scrolls at all.
set -u
BIN=$1; LOG=$2; TITLE=$3; shift 3
S=$(dirname "$LOG"); export YDOTOOL_SOCKET=/run/ydotoold/socket
cd ~/playground
setsid "$BIN" --gtk-single-instance=false --scroll-trace=true --title="$TITLE" "$@" -e yazi "$HOME/playground" > "$LOG" 2>&1 &
GP=$!; sleep 3
H=$S/hover-$TITLE.txt; : > $H
setsid ya sub hover > $H 2>&1 & YP=$!; sleep 1
cat > $S/act.js <<JS
var w = workspace.windowList();
for (var i = 0; i < w.length; i++)
  if (String(w[i].caption).indexOf("$TITLE") >= 0) workspace.activeWindow = w[i];
JS
qdbus-qt6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript act >/dev/null 2>&1
qdbus-qt6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript $S/act.js act >/dev/null
qdbus-qt6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null; sleep 0.5
h0=$(wc -l < $H); ydotool key 36:1 36:0 >/dev/null; sleep 0.6
if [ "$(wc -l < $H)" -le "$h0" ]; then echo "PROBE FAILED: no hover after j; aborting"; kill $YP $GP; exit 1; fi
echo "probe ok"
for k in $(printf 'j %.0s' $(seq 20)) $(printf 'k %.0s' $(seq 20)); do
  n0=$(wc -l < $LOG); h0=$(wc -l < $H)
  case $k in j) c=36;; k) c=37;; esac; ydotool key $c:1 $c:0 >/dev/null; sleep 0.45
  h=$(tail -n +$((h0+1)) $H | sed 's/.*playground\///; s/"}//' | tr '\n' ' ')
  echo "== $k -> ${h:-<no hover!>}"
  tail -n +$((n0+1)) "$LOG" | grep -E 'repaintscroll|scroll event' | sed 's/^.*\(repaintscroll\|scroll event\)/  \1/'
done
kill $YP; kill $GP; sleep 1; kill -0 $GP 2>/dev/null && echo "ghostty $GP still alive" || echo "closed ghostty $GP"
