#!/bin/sh
# phosh.service ExecStartPre: write /tmp/phoc.ini for phoc's X11 backend. The output mode must equal the
# Termux:X11 root size or touch/pixels are offset; a missing mode gives phoc's 1024x768 default. Before the
# Android app attaches, the X server reports its pre-attach default (1280x1024, from the app's prefs), so
# prefer the panel size recorded in /etc/aohp/panel-size (WxH of the fullscreen Termux:X11 surface) and
# fall back to the live root size only when no such file exists.
export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp
if [ -s /etc/aohp/panel-size ]; then sz=$(cat /etc/aohp/panel-size); else sz=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2}'); fi
[ -n "$sz" ] || sz=1440x3008
cat > /tmp/phoc.ini <<EOF
[core]
xwayland=false
[output:X11-1]
mode = $sz
scale = 3
EOF
echo "phoc.ini mode=$sz"
