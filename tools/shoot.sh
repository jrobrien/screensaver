#!/bin/bash
# Run a saver in a real alacritty on a private Xvfb display (xctl) and
# screenshot it at intervals. Never touches the live desktop.
#
#   tools/shoot.sh OUT-PREFIX [saver args...]
#
# Env: SAVER   command to run (default: bin/saver, the Python one)
#      SHOTS   seconds at which to capture (default "4 12")
#      SIZE    screen size (default 1920x1080)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
prefix=${1:?usage: shoot.sh OUT-PREFIX [saver args...]}; shift
saver=${SAVER:-$here/bin/saver}
disp=$(xctl start -g "${SIZE:-1920x1080}")
trap 'xctl stop "$disp" >/dev/null' EXIT
# Same look as Omarchy's screensaver terminal: black, 18pt, no padding.
WAYLAND_DISPLAY= DISPLAY=$disp alacritty --class org.omarchy.screensaver \
  --config-file /usr/share/omarchy/default/alacritty/screensaver.toml \
  -o 'window.startup_mode="Maximized"' \
  -e "$saver" --max-seconds 60 "$@" &
prev=0
for s in ${SHOTS:-4 12}; do
  sleep "$(python3 -c "print(max(0, $s - $prev))")"; prev=$s
  DISPLAY=$disp import -window root "$prefix-$s.png"
done
