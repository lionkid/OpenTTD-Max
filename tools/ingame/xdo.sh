#!/bin/sh
# Helpers for driving a held QA game (tools/ingame/run.py --hold N) on the Xvfb display.
#   tools/ingame/xdo.sh con "scrollto 6184"    type a console command
#   tools/ingame/xdo.sh click X Y              left click at screen position
#   tools/ingame/xdo.sh shot out.png           capture the whole screen
export DISPLAY=:99
case "$1" in
  con)   xdotool mousemove 640 480; xdotool key grave; sleep 0.4; xdotool type --delay 15 "$2"; xdotool key Return; sleep 0.3; xdotool key grave; sleep 0.4 ;;
  click) xdotool mousemove "$2" "$3"; sleep 0.2; xdotool click 1; sleep 0.6 ;;
  rclick) xdotool mousemove "$2" "$3"; sleep 0.2; xdotool click 3; sleep 0.6 ;;
  key)   xdotool key "$2"; sleep 0.4 ;;
  shot)  import -display :99 -window root "$2" ;;
  *) echo "usage: $0 con CMD | click X Y | rclick X Y | key KEY | shot FILE"; exit 1 ;;
esac
