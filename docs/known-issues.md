# Known issues and caveats (2026-10-04 builds)

## Dev-build security posture
`WITH_ADB_INSECURE=true`: adb is on at first boot with **no authorization prompt**, in Android and in recovery
(`ro.adb.secure=0`, `ro.debuggable=1`, `persist.sys.usb.config=adb`). Anyone with the cable owns the phone. Intended for
test devices; rebuild without the knob (and drop the `persist.sys.usb.config=adb` line in `vendor/aohp/aohp.mk`) for
anything else. `ro.secure=1` is unchanged, so `adb root` still needs **Developer options → Rooted debugging**
(Lineage's `adbroot_service`; "ADB Root access is disabled by system setting" until then). Not needed for AOHP work.

## AOHP-domain SELinux denials on the OnePlus 13 (harmless, noisy)
Pixel 6: zero AOHP denials. OnePlus 13: none at boot, then from the moment a container runs, all in
`scontext=u:r:aohp_container_daemon` (= processes inside the env). Counts from the first 4 minutes
(`op13-avc-classification.log`):

| count | denial | who | note |
|---|---|---|---|
| 144 | `read` `proc_stat:file` | `openclaw-gatewa` | the gateway reads `/proc/stat` ~1/s for load; grows to ~2000 lines/20 min and keeps filling the audit log |
| 65 | `create` `anon_inode` (`[io_uring]`) | Node threads (MainThread/WorkerThread/DelayedTaskSche/V8Worker) | Node 24's libuv probing io_uring, falls back to the threadpool; not seen on the Pixel's 6.1 kernel |
| 11 | `read` `proc_filesystems` | `sed`, `install` | bootstrap/apt tooling |
| 4 | capability `sys_ptrace` | `pgrep` | process listing over /proc |
| 4 / 3 / 2 | `read` `proc_version` / `proc_overcommit_memory` / `proc_uptime` | openclaw / python3 / node | diagnostics |
| 3 | `ioctl` 0x9409 on `aohp_container_data_file` | `install`, `mkdir`, `ls` | FICLONE / FS_IOC_* probes by coreutils, fall back to copy |

Nothing failed because of them (bootstrap, gateway, model calls, pairing all worked). Fix = `allow aohp_container_daemon
proc_*:file r_file_perms;` + `anon_inode create` in the AOHP sepolicy (upstream issue tracked in the aohp-os sepolicy
PR set). The ~90 non-AOHP denials on dodge (mediacodec/default_prop, vendor_location, oplus daemons, `shell` from our own
`service list`/`ss`) are stock Lineage/vendor noise.

## Phone capabilities for the OpenClaw app
All node permissions start **false**; choose them in the app's *Settings → Phone Capabilities*. Never `adb install -g`
or `pm grant` the app's runtime permissions — pre-granting skips its onboarding chooser and leaves Camera/Location
"Locked"; revoking later restarts onboarding. `POST_NOTIFICATIONS` is the exception (`pm grant` is fine).
`camera.snap/clip`, `screen.record`, contacts/calendar/sms **writes** are refused until
`gateway.nodes.commands.allow: ["camera.snap", …]` is in the env's `openclaw.json`; `camera.*` also needs the app
in the foreground. Each widening creates a new `openclaw nodes approve` request.

## Container templates
- The 2026-10-04 ROMs carry the hand-built Debian template (617 MB compressed; the reproducible
  [templates-20261005](https://github.com/injinj/aohp-agents/releases/tag/templates-20261005) Debian is 382 MB / 1.36 GB
  uncompressed and will be in the next build). Fedora 44 (402 MB / 1.36 GB) is a sound alternative; **Arch is not
  recommended on-device** (518 MB / 1.86 GB — over the RAM-inflation budget; pacman needs `DisableSandbox`; gdb's Guile
  mtime problem; third-party arm64 base image).
- Only one env can run a gateway (shared netns → only one `:18789`); a second shows PORT BUSY / EADDRINUSE.
- containerd quirks: `execSync` runs only the first line of a script (send scripts as one base64 line); exited
  `openShell` children are not reaped (zombie `[sh]`); file mtimes are not restored on template extraction; tar type-K
  (long symlink target) entries are dropped (a few CA-cert hash links in fedora/arch); `svc-stop` wrapper-only kill on
  older builds (these ROMs have the stop-pgid fix).
- /data: an env is ~1.4 GB (debian) once inflated; the OnePlus has plenty, the Pixel 6 128 GB is fine too.

## Driver app nits (0.2.0)
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
