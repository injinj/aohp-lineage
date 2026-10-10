#!/bin/bash
export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp HOME=/root
systemctl stop squeekboard phosh 2>/dev/null; sleep 2
( timeout 24 gamescope -W 1440 -H 3008 -f --backend sdl --expose-wayland -- vkcube --wsi wayland > /tmp/gs-E.log 2>&1; echo "rc=$?" >> /tmp/gs-E.log ) &
sleep 14
echo "== E (wayland direct)"; grep -v -E "vulkan:   [A-Z0-9]{4}" /tmp/gs-E.log | grep -i -E "dmabuf|error|fail|rc=|assert|Selected|fps|xdg" | tail -8 | cut -c1-160
sleep 12
( timeout 24 gamescope -W 1440 -H 3008 -f --backend sdl -- vkcube > /tmp/gs-F.log 2>&1; echo "rc=$?" >> /tmp/gs-F.log ) &
sleep 14
echo "== F (xcb via layer)"; grep -v -E "vulkan:   [A-Z0-9]{4}" /tmp/gs-F.log | grep -i -E "dmabuf|error|fail|rc=|assert|Gamescope WSI\] (Made|Failed|Creating)|fps" | tail -8 | cut -c1-160
sleep 12
systemctl start phosh; sleep 5; systemctl start squeekboard
