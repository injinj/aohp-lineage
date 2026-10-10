# Phosh as a unit (OnePlus 13, dodge build-18+)

Copies of the env-side files described in [docs/gpu.md](../../docs/gpu.md#phosh-as-the-shell-env-only).

```
apt install phoc phosh phosh-core squeekboard gnome-console gnome-text-editor gnome-calculator dbus-daemon xkb-data
install -m644 dbus-system.service phosh.service squeekboard.service /etc/aohp/system/
install -m644 dbus-system.conf /etc/aohp/
install -m755 phoc-ini-gen.sh /usr/local/bin/phoc-ini-gen
install -m755 phosh-session-wrap /usr/local/bin/
echo 1440x3008 > /etc/aohp/panel-size      # fullscreen Termux:X11 surface, WxH
systemctl daemon-reload && systemctl enable --now dbus-system phosh squeekboard
```

Then in the Termux:X11 app: Fullscreen on, additional keyboard off, touch mode = **simulated touch** (direct touch makes every launch wait out Phosh's 5 s splash timeout — see docs/gpu.md).
Requires `x11.service` from `docs/units.md` without `-legacy-drawing`.
