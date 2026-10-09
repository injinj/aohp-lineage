# Units — systemd-style services inside the agent container (build-5 / build-3, 2026-10-05)

The container has no PID namespace (GKI kernels on the Pixel 6 / OnePlus 13 lack `CONFIG_PID_NS`), so a real
systemd or dinit cannot run inside it. Instead **aohp-containerd** (the Android-side daemon that already forks every
container process) supervises *units* declared in the container — the subset of systemd that runs OpenClaw on a
Linux box: `Restart=`, ordering, timers. The AOHP Driver 0.4.0 shows them (Harness → *Units*), the `aohp` CLI
drives them from any host (`aohp unit <env> …`), and a `systemctl` / `journalctl` **shim** inside the container keeps
muscle memory and scripts working.

Authoritative spec: [aohp-driver docs/UNITS.md](https://github.com/injinj/aohp-driver/blob/master/docs/UNITS.md).
Template side (shipped units, shim verbs, writing a unit): [aohp-agents docs/units.md](https://github.com/injinj/aohp-agents/blob/main/docs/units.md).

## Unit files

`/etc/aohp/system/<name>.service`, `<name>.timer`; enabled = symlink in `/etc/aohp/system/aohp.target.wants/`.
containerd writes the env's name to `/etc/aohp/env-name`. Logs: `/data/aohp/envs/<env>/.aohp/log/<unit>.log`
(rotated to `.1` at 1 MB on (re)start), readable with `journalctl -u <unit>` / `aohp unit <env> log <unit>`.

| section | supported | notes |
|---|---|---|
| `[Unit]` | `Description After Before Requires Wants ConditionPathExists` | ordering is topological (cycle → load error); a failed `Requires=` fails dependents and a stopped/failed required unit stops them; `!` negates the condition |
| `[Service]` | `Type=simple\|oneshot`, `ExecStartPre/ExecStart/ExecStartPost/ExecStop/ExecReload` (`-` prefix), `RemainAfterExit`, `Restart=no\|always\|on-failure\|on-abnormal\|on-success`, `RestartSec`, `StartLimitBurst/StartLimitIntervalSec` (5 in 60 s → `failed (start-limit-hit)`), `SuccessExitStatus`, `Environment`, `EnvironmentFile` (`-`), `WorkingDirectory`, `TimeoutStopSec` (SIGTERM→SIGKILL, 30 s), `TimeoutStartSec`, `KillMode=control-group\|process` | `Type=notify/forking`, `User=`, `Limit*`, socket activation: **not** supported (notify/forking → load error, the others warn) |
| `[Timer]` | `OnBootSec` (from env start), `OnUnitActiveSec`, `OnCalendar=minutely\|hourly\|daily\|weekly\|*-*-* HH:MM:SS\|HH:MM`, `Unit`, `Persistent` | other calendar expressions → load error |
| `[Install]` | `WantedBy=aohp.target` | |

Exec lines run as `/bin/sh -c` (root) in a fresh mount namespace with the usual binds, own process group,
stdout/stderr → unit log, env = containerd defaults + `Environment=` + `EnvironmentFile=` + `AOHP_ENV`/`AOHP_UNIT`
(`$MAINPID` for ExecStop/ExecReload). Unknown keys only warn.

## HostExec= — units that run on the Android side (dodge build-8, 2026-10-09)

`HostExec=yes` in `[Service]` makes containerd spawn the unit **on the Android host** instead of in the chroot:
no mount namespace, no bind mounts, no `chroot`; the shell is `/system/bin/sh`, `PATH` is the Android one,
`ExecStart`/`WorkingDirectory`/`EnvironmentFile` are host paths, and the env's rootfs is exported as
`$AOHP_ROOTFS` (`/data/aohp/envs/<env>/rootfs`). Everything else is unchanged — the process joins the env's
cgroup, so `stop`, `KillMode`, `Restart`, logs and *Stop env* behave exactly as for in-container units, and it
runs in the container daemon's SELinux domain (which is what the sepolicy grants are written for). It is the
WSL "interop" idea: the env declares a dependency on something only the host can run.

First user: the display. `x11.service` runs the **Termux:X11** server (`app_process … com.termux.x11.CmdEntryPoint :0`,
a real X server that draws into that app's window; the APK is a separate GPL-3 install, `com.termux.x11`) with
`TMPDIR=$AOHP_ROOTFS/tmp`, so X clients in the env find it at `/tmp/.X11-unix/X0`. GPU access comes from Mesa in
the env opening `/dev/kgsl-3d0` directly (OnePlus 13; see the GPU section of the README). App units then just say

```ini
[Unit]
Requires=x11.service
After=x11.service
[Service]
EnvironmentFile=/etc/aohp/x11.env     # DISPLAY=:0 XDG_RUNTIME_DIR=/tmp MESA_LOADER_DRIVER_OVERRIDE=kgsl
ExecStart=/usr/bin/love /srv/games/bounce
```

and `systemctl start love-bounce` brings the display up as a side effect; `systemctl stop x11` takes every X client
down with it. Shipped examples: `x11.service`, `glxgears.service`, `xterm.service`, `love-bounce.service`
(a LÖVE game under `/srv/games/bounce`). No window manager by default — each app fills the phone screen; add
`openbox.service` (`Requires=x11.service`) when docked. Template units (`name@.service`, `%i`) are not supported.

## What the template ships (`templates-20261005c`)

`openclaw-gateway.service` (**enabled** — `Restart=on-failure`, `RestartSec=5`, `SuccessExitStatus=0 143`,
`EnvironmentFile=-/root/.openclaw/env.sh`, `WorkingDirectory=/root/.openclaw/workspace`, `After/Wants=wg0.service`),
`wg0.service` (oneshot `wg-quick up wg0`, condition on `/etc/wireguard/wg0.conf`), `sshd.service`
(`ssh-keygen -A` + `sshd -t` pre, `-D -E /var/log/sshd.log`, condition on the `10-aohp.conf` drop-in),
`net-watchdog.service/.timer` (one `wg0-sshd-startup.sh` pass, 2 min after env start then every 5 min),
`openclaw-watchdog.service/.timer` (`/health` probe, 3 failures → restart the gateway unit; 3 min then every 2 min).
Everything but the gateway is disabled until you `systemctl enable --now` it.

## Day to day

```sh
# inside the container (Driver Terminal tab, or ssh over wg0)
systemctl status openclaw-gateway            # ● … Loaded / Active (running) since … / Main PID / Restart: on-failure
systemctl restart openclaw-gateway
journalctl -u openclaw-gateway -n 100
systemctl list-units ; systemctl list-timers
systemctl enable --now wg0 sshd net-watchdog.timer openclaw-watchdog.timer
systemctl daemon-reload                      # after editing /etc/aohp/system/*.service

# from chex
aohp --url ws://PHONE:6666 unit oc list
aohp unit oc status sshd ; aohp unit oc log sshd -n 50 ; aohp timer oc list
aohp unit oc env-start | env-stop            # what the Driver's Autostart / Stop env do
```

**Autostart** (Harness → env card) now means *env-start*: containerd starts the env's enabled units in dependency order
and keeps them up. Envs without unit files keep the 0.3.0 behaviour (replay of the services recorded by the Driver).
The Harness *Units* card lists every unit with state badge, sub-state, pid/uptime or next elapse, restart count and
start/stop/restart/enable/disable/log buttons, plus *Reload*, *Start env*, *Stop env*.

## Migrating an env created before build-5 / build-3

1. Sideload the new ROM (`/data` and envs are kept) — the new containerd and Driver 0.4.0 are in the image.
2. In the env: `aohp-update` (or `bash /opt/aohp-agents/install/units.sh`) installs the unit files and shims and
   enables `openclaw-gateway.service`. The Driver's "Start gateway" button and the old
   `aohp sandbox svc-start -i openclaw-gateway` now start that unit (containerd maps the service id onto the unit file).
3. Hand-started network services (the Pixel 6 setup from provisioning §E — `wg-quick up wg0`, `sshd`, the
   `net-watchdog` svc-start loop): `systemctl enable --now wg0 sshd net-watchdog.timer`, then stop the old
   transient `net-watchdog` (`aohp sandbox svc-stop -n oc -i net-watchdog`) and kill the hand-started `sshd` once
   (`pkill -x sshd`; the unit's `sshd` takes over on the next timer pass or `systemctl restart sshd`). A reboot does the
   same: Autostart = env-start.
4. Optional: `systemctl enable --now openclaw-watchdog.timer`.

## Known gaps

No socket activation, `User=`, sd_notify / `Type=forking`, cgroup keys per unit, `OnCalendar` beyond the subset,
`systemctl edit/mask`, `--user`, `journalctl -f` (polled every 2 s in the shim). Timers do not survive an env stop
unless `Persistent=yes`. The start limit applies to automatic restarts (a manual `start` resets it).
