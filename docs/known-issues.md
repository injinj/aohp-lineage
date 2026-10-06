# Known issues and caveats (2026-10-05 builds: oriole build-4, dodge build-2)

## Dev-build security posture
`WITH_ADB_INSECURE=true`: adb is on at first boot with **no authorization prompt**, in Android and in recovery
(`ro.adb.secure=0`, `ro.debuggable=1`, `persist.sys.usb.config=adb`). Anyone with the cable owns the phone. Intended for
test devices; rebuild without the knob (and drop the `persist.sys.usb.config=adb` line in `vendor/aohp/aohp.mk`) for
anything else. `ro.secure=1` is unchanged, so `adb root` still needs **Developer options → Rooted debugging**
(Lineage's `adbroot_service`; "ADB Root access is disabled by system setting" until then). Not needed for AOHP work.

## SELinux: what the 2026-10-05 builds fixed, and what is still denied
sepolicy commit `38feaf914` (`private/aohp_container_daemon.te`) grants the container domain:

- `self:netlink_audit_socket` — libaudit users (**sshd**, PAM, sudo, su) got EPERM on the audit socket and sshd dropped
  every interactive session; the Pixel 6 env needed an `LD_PRELOAD libnoaudit.so` shim. **Not needed any more.**
- the dodge noise from `op13-avc-classification.log`: `proc_stat` (144×, gateway ~1/s), `proc_filesystems`,
  `proc_version`, `proc_uptime`, `proc_overcommit_memory` (+ `proc_loadavg`) reads; `anon_inode` create (65×,
  libuv io_uring probe → `io_uring_use()`); `FICLONE` 0x9409 (+ FICLONERANGE, FIDEDUPERANGE, TCGETS2, FS_IOC_GETFLAGS/
  SETFLAGS/FIEMAP) on container files;
- `sysfs_dm` dir search + file read — `dnf` (Fedora template) reads `/sys/block/dm-*/queue/rotational`.

**Still denied (by design):** `self:capability sys_ptrace` — `pgrep -f <host pid>` / reading another uid's
`/proc/<pid>/cmdline` inside the container. Lineage's `private/domain.te` neverallows `sys_ptrace` for every domain
outside a fixed allowlist (vold, dumpstate, storaged, system_server, …); we do not weaken neverallows. `pgrep -x <comm>`,
`pidof`, `kill -0` work (the pid-probe fix). Expect 4 such denials per container start; harmless.

The ~90 non-AOHP denials on dodge (mediacodec/default_prop, vendor_location, oplus daemons, `shell` from our own
`service list`/`ss`) are stock Lineage/vendor noise. Verify a flashed build: `logcat -b all -d | grep avc | grep aohp_container`
should show only the sys_ptrace lines after bootstrap + gateway start.

## Network services in the env (WireGuard + sshd)
The templates-20261005b Debian/Fedora/Arch templates ship `wireguard-tools` and `openssh-server` **installed but
inactive** plus `/opt/aohp-agents/net/` (`wg0-sshd-startup.sh` watchdog, `10-aohp.conf.template` sshd drop-in). Recipe
(also in [provisioning.md](provisioning.md) §E): put `wg0.conf` in `/etc/wireguard/`, copy the drop-in with the wg0
address as ListenAddress, add your pubkey, run `wg0-sshd-startup.sh` once, then register it as a service so the Driver's
Autostart restarts it at boot:
`aohp sandbox svc-start -n <env> -i net-watchdog -C "/usr/local/bin/wg0-sshd-startup.sh --loop 300"`.
Caveats: the container shares the phone's netns — bind sshd to the wg0 address only, never wildcard; Android ignores the
main routing table, so the watchdog keeps an `ip rule … lookup 51820` per AllowedIPs subnet; `UsePAM no` is required
(PAM account/session stacks cannot work in the container). `net-watchdog.json` in `/var/run/aohp-cron/` shows
`handshakeAgeSec` / `sshdPid`.

## Phone capabilities for the OpenClaw app
All node permissions start **false**; choose them in the app's *Settings → Phone Capabilities*. Never `adb install -g`
or `pm grant` the app's runtime permissions — pre-granting skips its onboarding chooser and leaves Camera/Location
"Locked"; revoking later restarts onboarding. `POST_NOTIFICATIONS` is the exception (`pm grant` is fine).
`camera.snap/clip`, `screen.record`, contacts/calendar/sms **writes** are refused until
`gateway.nodes.commands.allow: ["camera.snap", …]` is in the env's `openclaw.json`; `camera.*` also needs the app
in the foreground. Each widening creates a new `openclaw nodes approve` request.

## Container templates
- The 2026-10-05 ROMs carry the reproducible
  [templates-20261005b](https://github.com/injinj/aohp-agents/releases/tag/templates-20261005b) Debian (407 MB / 1.38 GB
  uncompressed; the 2026-10-04 ROMs had the hand-built 617 MB predecessor). Fedora 44 (429 MB) is a sound alternative;
  **Arch is not recommended on-device** (>500 MB / 1.86 GB — over the RAM-inflation budget; pacman needs `DisableSandbox`;
  gdb's Guile mtime problem; third-party arm64 base image). A new template does not touch existing envs in /data.
- Only one env can run a gateway (shared netns → only one `:18789`); a second shows PORT BUSY / EADDRINUSE.
- containerd quirks: `execSync` runs only the first line of a script (send scripts as one base64 line); exited
  `openShell` children are not reaped (zombie `[sh]`); file mtimes are not restored on template extraction; tar type-K
  (long symlink target) entries are dropped (a few CA-cert hash links in fedora/arch); `svc-stop` wrapper-only kill on
  older builds (these ROMs have the stop-pgid fix).
- /data: an env is ~1.4 GB (debian) once inflated; the OnePlus has plenty, the Pixel 6 128 GB is fine too.

## Driver app nits (0.3.0)
- 0.3.0: Autostart replays **every service recorded for the env** (anything started via Harness, the wizard or
  `aohp sandbox svc-start` and not stopped since), gateway last; an env with nothing recorded gets just the gateway as
  before. Services started on a 0.2.0 Driver before the update are **not** in the registry — start them once more (or
  svc-stop/svc-start) after flashing so they are recorded.
- Harness "Secrets (names only)" card calls `aohp-secrets list`, which is not a subcommand — should be `aohp secret list`.
- The Autostart switch is UI state; an env created from the CLI starts with it **off**.
- A sideloaded Driver in `/data/app` shadows the system copy after a ROM update; `pm uninstall org.aohp.driver` drops back
  to `/system/app` and keeps app data (Keystore secrets, Autostart) when versionCodes are equal.
- Keystore is per-app: migrate secrets before disabling any old `org.aohp.agentdriver` install (not present in these ROMs).

## ROM / device
- No GApps. On the Pixel the vendor `com.google.euiccpixel` crash-loops in logcat without gservices (eSIM app; harmless).
- Pixel 6 slot a still holds the pre-OTA boot images / old system; the next OTA overwrites it. OnePlus slot a's logical
  partitions are deleted by the Virtual A/B install (slot a not bootable; expected).
- OnePlus: `fastboot erase userdata` hangs; `super` must never be fastboot-flashed from a partial image (see install-dodge.md).
- `ro.build.date` does not change on incremental image builds — verify a flash by content, not by date.
- The config repo working trees inside the envs created on 2026-10-04 are dirty (`openclaw.json`, `workspace/AGENTS.md`
  patched on the phone; the same changes are now committed upstream in the config repo / aohp-agents) — `git status`
  inside `/root/.openclaw` will show them; `git checkout -- .` + `aohp-update` is safe.

## Units (build-5 / dodge-3)

- Not implemented: socket activation, `User=`, `Type=notify`/`forking` (load error), per-unit cgroup keys, `OnCalendar`
  outside `minutely|hourly|daily|weekly|*-*-* HH:MM:SS|HH:MM`, `systemctl edit/mask/--user`, `journalctl -f` (polled).
  Timers are not persistent across an env stop unless `Persistent=yes`; the start limit counts automatic restarts only.
- Unit logs rotate only when the unit (re)starts (1 MB → `.log.1`); a long-running chatty service grows its log until then.
- The CLI's `aohp unit <env> start X` exits 1 when X was skipped by a `ConditionPathExists` (systemd would exit 0).
- The daemon-side unit manager was exercised on Cuttlefish (own test daemon, same source) and the Driver/CLI/shim path through
  a mock bridge; the Binder `unitControl` path and the Units card were compile-verified only before release (no phone was
  flashed for this build). Report anything odd in the Harness Units card with `adb logcat -s aohp-containerd AohpContainer`.

## Queued for next build (oriole build-6 / dodge build-4) — 2026-10-05

- **Drop `WITH_ADB_INSECURE=true`** (`ro.adb.secure=1`) and add `PRODUCT_ADB_KEYS := vendor/aohp/adb_keys` holding the build host's `~/.android/adbkey.pub` (plus any other trusted host). The build host keeps zero-touch scripted access from first boot; any other USB host gets the authorization dialog. Keep `persist.sys.usb.config=adb`. The sideload path is unchanged (`adb reboot sideload` is issued from the authorized booted system).
- **Lock-screen PIN / direct boot.** With a PIN set, user 0 stays `RUNNING_LOCKED` after reboot, `BOOT_COMPLETED` is withheld and the Driver is not direct-boot aware, so the bridge, env-start and the gateway wait for the first unlock (once per boot; locking the screen afterwards is fine). Either make the Driver `directBootAware` (bridge + env-start on `LOCKED_BOOT_COMPLETED`; gateway start on `ACTION_USER_UNLOCKED` while the Keystore key is CE-bound) or document "no PIN on headless AOHP phones" in provisioning.md.
- `aohp-update` must run `install/units.sh` (docs already say it does); ship the `aohp` CLI (feat/units) as an aohp-agents release asset — it is too large for the binder base64 file push.
- Template `sshd.service`: use `-D -e` instead of `-E <file>` so `journalctl -u sshd` shows output.
- Driver: Autostart switch default **on** (currently a UI-only preference, default off).
- Sepolicy: `ss` is denied in the shell domain on build-3/5 — scripts should read `/proc/net/tcp`, or allow it. Optional allow for the remaining AOHP denial (`openclaw-gatewa` reading sysfs `model`).
- Pixel 6 gateway cold start is 52–71 s vs 10 s on the OnePlus 13 with the same unit/template — investigate.
- Unit `Main PID` is the `sh -c` wrapper; consider `exec` in the wrapper or direct spawn when `ExecStart` has no shell syntax.
- **Sepolicy: TUN for the container** — `tailscaled` (and any userspace VPN) fails `TUNSETIFF` with EPERM; today it runs `--tun=userspace-networking` (netstack, inbound-only, no interface). Add `allow aohp_container_daemon tun_device:chr_file { read write open ioctl };` (+ `self:tun_socket { create read write }` if the tree requires it) and make `/dev/tun` reachable (ueventd `0666` or containerd chown). Then tailscaled gets a real `tailscale0` with a 100.x address and outbound works for all processes.
- **Sepolicy/caps: audit netlink** — pty logins through sshd need `audit_session_open`; grant `CAP_AUDIT_WRITE` to the container and `allow aohp_container_daemon self:netlink_audit_socket { create read write nlmsg_relay }` + `capability audit_write`, then drop the `libnoaudit.so` LD_PRELOAD and `UsePAM no` workarounds.
