# Known issues and caveats (2026-10-06 builds: oriole build-6, dodge build-4; 2026-10-05: oriole build-5, dodge build-3)

## Dev-build security posture
**Since oriole build-6 / dodge build-4 (2026-10-06):** normal Lineage userdebug — `ro.adb.secure=1`, `ro.debuggable=0`,
`persist.sys.usb.config=adb`. The build host's adb public key (`vendor/aohp/adb_keys` = chex `~/.android/adbkey.pub`,
`PRODUCT_ADB_KEYS`) is installed as `/product/etc/security/adb_keys` (`/adb_keys` symlinks to it), so chex gets adb from first
boot with no RSA dialog (verified on both phones 2026-10-06); any other USB host sees the usual authorization prompt. The
recovery-ramdisk copy (`aohp_adb_keys_recovery`) landed at `/system/adb_keys` instead of `/adb_keys`, so **recovery adb is
`unauthorized`** on these builds (sideload is unaffected; the post-sideload reboot needs a tap — see the 2026-10-06 section), and the phone's own `/data/misc/adb/adb_keys` stays empty unless
someone taps "Always allow". Adding a host = append its `adbkey.pub` line to `vendor/aohp/adb_keys` and rebuild. The
network adb on dodge (`persist.adb.tcp.port=5555`) is now authenticated too.
`ro.debuggable=0` does **not** remove `adb root`: adbd on a userdebug build is compiled with `ANDROID_DEBUGGABLE`
(`packages/modules/adb/daemon/main.cpp` `should_drop_privileges()`), so `adb root` works and Lineage's *Rooted debugging*
toggle (`service.adb.root=1`) keeps adbd root across boots - verified on the Pixel on build-6 (`id -u` = 0). An earlier note here
claimed the opposite; that was a misread of a test (`0` from `id -u` *is* root).

Builds ≤ oriole build-5 / dodge build-3 were built with `WITH_ADB_INSECURE=true` (`ro.adb.secure=0`, `ro.debuggable=1`):
anyone with the cable owned the phone, in Android and in recovery.

## SELinux: what the 2026-10-05 builds fixed, and what is still denied
sepolicy commit `38feaf914` (`private/aohp_container_daemon.te`) grants the container domain:

- `self:netlink_audit_socket` — libaudit users (**sshd**, PAM, sudo, su) got EPERM on the audit socket and sshd dropped
  every interactive session; the Pixel 6 env needed an `LD_PRELOAD libnoaudit.so` shim. **Not needed any more.**
- the dodge noise from `op13-avc-classification.log`: `proc_stat` (144×, gateway ~1/s), `proc_filesystems`,
  `proc_version`, `proc_uptime`, `proc_overcommit_memory` (+ `proc_loadavg`) reads; `anon_inode` create (65×,
  libuv io_uring probe → `io_uring_use()`); `FICLONE` 0x9409 (+ FICLONERANGE, FIDEDUPERANGE, TCGETS2, FS_IOC_GETFLAGS/
  SETFLAGS/FIEMAP) on container files;
- `sysfs_dm` dir search + file read — `dnf` (Fedora template) reads `/sys/block/dm-*/queue/rotational`.

sepolicy `a20ebb2f2` + `2e2f4c0e6` (build-6 / dodge-4) add `self:capability audit_write` (+ `AUDIT_WRITE` in the containerd
rc, core `503e963d2`) — the netlink socket alone was not enough, the *send* needs `CAP_AUDIT_WRITE`. Two more grants were
tried and **reverted because they violate neverallows**: a generic `sysfs:file` read for the `openclaw-gatewa` `model`
probe (`private/coredomain.te:142`, coredomain may not touch unlabeled sysfs; the node would need its own label) and
`shell self:netlink_tcpdiag_socket` for `ss` (`private/app.te:567`, no appdomain gets sock_diag). Both stay denied and
harmless; scripts keep reading `/proc/net/tcp`.

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

## GPU / display in the env (dodge build-15, 2026-10-09)

- OnePlus 13 only. GL via Mesa turnip/freedreno on `/dev/kgsl-3d0` works enforcing (`glxgears` 60 FPS vsynced); the env needs
  a Mesa ≥ 26 built with `-Dfreedreno-kmds=msm,kgsl` (lfdevs tarball over Debian's 25.0.7) and Termux:X11 installed separately
  (GPL-3). Recipe and sepolicy inventory: [gpu.md](gpu.md).
- Since dodge build-18: `/dev/shm` is a real per-container tmpfs, `zink` and `vkcube` work, Termux:X11 refreshes per frame
  (build-16), and Phosh runs as a unit ([gpu.md](gpu.md#phosh-as-the-shell-env-only)). Still open: the phoc **compositor
  cannot use the GPU** on the nested X11 backend (no DRI3 DRM fd on KGSL) — pixman only; Settings → Displays crashes.
  Residual harmless denials: `vendor_sysfs_kgsl` symlink read (vendor policy is
  the OEM's on dodge), `vendor_overlay_file` stat (coredomain neverallow), `love`'s TCGETS ioctl on `/proc/*/mountinfo`.
- Pixel 6: no GPU in the env yet (Mali has no open userspace; a host-side virgl proxy is scoped, not built).
- Template units (`name@.service`) are not supported, so one unit per game/app.

## Units (build-5 / dodge-3)

- Not implemented: socket activation, `User=`, `Type=notify`/`forking` (load error), per-unit cgroup keys, `OnCalendar`
  outside `minutely|hourly|daily|weekly|*-*-* HH:MM:SS|HH:MM`, `systemctl edit/mask/--user`, `journalctl -f` (polled).
  Timers are not persistent across an env stop unless `Persistent=yes`; the start limit counts automatic restarts only.
- Unit logs rotate only when the unit (re)starts (1 MB → `.log.1`); a long-running chatty service grows its log until then.
- The CLI's `aohp unit <env> start X` exits 1 when X was skipped by a `ConditionPathExists` (systemd would exit 0).
- The daemon-side unit manager was exercised on Cuttlefish (own test daemon, same source) and the Driver/CLI/shim path through
  a mock bridge; the Binder `unitControl` path and the Units card were compile-verified only before release (no phone was
  flashed for this build). Report anything odd in the Harness Units card with `adb logcat -s aohp-containerd AohpContainer`.

## 2026-10-06 builds (oriole build-6 / dodge build-4) — what changed

Built overnight 2026-10-05/06, **flashed and verified on both phones 2026-10-06 02:07–02:50 PDT**. Report: `/home/chris/lineage/logs/REPORT-build-6-4.md`.
Both built rc=0 (dodge-4 6 min, build-6 17.5 min, incremental): `lineage-23.2-20261006-UNOFFICIAL-dodge.zip` sha `cd3bce64…`,
`lineage-23.2-20261006-UNOFFICIAL-oriole.zip` sha `cbe60043…` (full lists `logs/artifacts-dodge-4.sha256`, `logs/artifacts-build-6.sha256`).
Releases: [oriole-23.2-20261006-build6](https://github.com/injinj/aohp-lineage/releases/tag/oriole-23.2-20261006-build6),
[dodge-23.2-20261006-build4](https://github.com/injinj/aohp-lineage/releases/tag/dodge-23.2-20261006-build4).
**dodge build-5** (freeform feature XML, vendor/aohp `36d33ea`) is being built now and follows as its own release; it differs
from build-4 only by that one XML.

**Update flow is now sideload-only.** The A/B payload carries boot/dtbo/vendor_boot/vbmeta (dodge also init_boot/recovery —
`META/ab_partitions.txt`), so a build-to-build update is `adb reboot sideload` from the booted system → `adb sideload <zip>` →
reboot; no fastboot pre-steps (oriole sideload 4:40, boot 160 s; dodge 3:26, boot 50 s; scripts `logs/flash6-flash.sh`,
`logs/op13f4-flash.sh`). **One manual tap:** after `sideload rc=0` the recovery's adbd comes back `unauthorized` on both phones
(even though the recovery doing the sideload was the previously authorized build-5/3 one), so the scripted `adb reboot` is
refused — Chris taps *Reboot system now*. On these builds recovery adb is unauthorized by design (the key is at
`/system/adb_keys` in the recovery ramdisk, not `/adb_keys`; queued below). Until that is fixed: sideload, then one manual reboot.

**Verified on both phones:** `ro.adb.secure=1`, chex's baked key accepted with no prompt; `ro.debuggable=0` but `adb root` still works
(userdebug adbd is compile-time debuggable; the *Rooted debugging* toggle keeps it root - an earlier claim that it was gone was a misread);
Driver 0.5.0 autostart with zero touches (bridge :6666, env-start → sshd, net-watchdog.timer, gateway `/health` live); F-Droid +
Privileged Extension present; CapEff bit 29 (AUDIT_WRITE) on `aohp-containerd`; Launcher3 patch live (no
`OverviewComponentObserver` crashes); the `Environment=LD_PRELOAD=libnoaudit.so` line **removed** from both envs'
`/etc/aohp/system/sshd.service` and interactive (pty) ssh works on both → CAP_AUDIT_WRITE proven. Only AOHP-domain denial left:
the sysfs `model` read (neverallow, harmless). Pixel: two pre-existing `com.google.euiccpixel` crashes at boot (also on build-5).
Commits (all on `lineage-23.2-aohp` of the injinj forks unless noted):

- **adb: `WITH_ADB_INSECURE` dropped, host key baked in** — vendor/aohp `204883a` (`PRODUCT_ADB_KEYS := vendor/aohp/adb_keys`,
  recovery-ramdisk copy via `vendor/aohp/Android.bp`). See "Dev-build security posture" above. **Morning flash:** after
  the sideload the phone comes up with `ro.adb.secure=1`; chex is authorized by key, so nothing changes in the scripted
  flow — if a dialog does appear on the phone, tap *Always allow* once (then `/data/misc/adb/adb_keys` also carries it).
  Caveat: the recovery-ramdisk copy landed at `/system/adb_keys` instead of `/adb_keys` (that path is the dangling
  `/product/…` symlink from `create_root_structure.mk`), so **plain recovery adb shows *unauthorized***; the update
  path is unaffected because `adb reboot sideload` is sent from booted Android and sideload mode runs minadbd, which
  never authenticates (`minadbd.cpp:87`). Fallback: recovery *Advanced → Enable ADB*. Queued: install it as `/adb_keys`.
  Seen in practice: after the sideload the recovery adbd is `unauthorized`, so the post-sideload `adb reboot` needs a tap (above).
- **Sepolicy / caps** — sepolicy `a20ebb2f2` + `2e2f4c0e6`, core `503e963d2`: `CAP_AUDIT_WRITE` + `audit_write` (sshd pty
  logins no longer need the `libnoaudit.so` LD_PRELOAD line — removed from `/etc/aohp/system/sshd.service` in both envs on
  2026-10-06, interactive `ssh` verified on both; `UsePAM no` stays). The `sysfs:file` read and the
  shell-domain `ss` grant **could not be added** (neverallows, see the SELinux section) — both stay denied, harmless.
  **TUN:** the `tun_device`/`tun_socket` rules were already in place since `cb9e9b8fa`; the `TUNSETIFF` EPERM of
  2026-10-05 produced no `avc:` line and the env's `CapEff` (0x2c30fb) includes NET_ADMIN, so it is not a policy denial
  — nothing was added; needs a live C/python probe (open `/dev/net/tun`, `TUNSETIFF`) with `dmesg` beside it.
- **Launcher3 taskbar NPE** — new repo project: `packages/apps/Launcher3` from `injinj/android_packages_apps_Launcher3`
  branch `lineage-23.2-aohp` (`626851073d`, one commit on LineageOS `lineage-23.2`): `OverviewComponentObserver` falls
  back to `QuickstepLauncher` when its own HOME intent resolves to null (AOSP main has no fix). Recorded in the injinj
  local manifest (`6513e9e`). Verified on dodge build-4: the docked display's taskbar no longer crashes (taps reach
  `TaskbarManager`).
- **dodge: desktop experience on external displays** — vendor/aohp `4cab818`: static framework-res overlay
  `config_isDesktopModeDevOptionSupported=true` (the gate; a product property alone is ignored on a phone) +
  `persist.wm.debug.desktop_experience_devopts=true`, both inside `ifeq ($(TARGET_PRODUCT),lineage_dodge)`. The phone
  screen stays a phone (`config_canInternalDisplayHostDesktops` untouched). **On hardware: necessary but not sufficient.**
  The taskbar on the external display draws and taps reach it, but launches died in WM Shell —
  `DesktopTasksController: createDeskImmediate displayId=2` / `Failed to add desk in displayId=2`. Root cause:
  `DesktopStateImpl.isDesktopModeSupportedOnDisplay` → `WindowManagerService.isEligibleForDesktopMode` →
  `displayContent.isWindowingModeSupported(FREEFORM)` is false on a phone without `android.software.freeform_window_management`,
  so no desk is created on display-added. **Fix verified at runtime:** `settings put global enable_freeform_support 1` + reboot →
  `createDesk displayId=2 → deskId=39`, apps open as windows on the monitor. Gotcha: a `settings put` immediately followed by
  `adb reboot` was **lost** (SettingsProvider flushes asynchronously) — wait ~5 s before rebooting. The external display comes
  up as its own display group (extended, not mirrored) with the `SecondaryDisplayLauncher` as home + the per-display taskbar.
  Image fix: vendor/aohp `36d33ea` (`PRODUCT_COPY_FILES` freeform feature XML in the dodge block) → **dodge build-5, being
  built now** (2026-10-06 morning); flash it with the sideload-only flow and confirm the dock gives a desk with no `settings put`.
- **F-Droid bundled** — vendor/aohp `2de181a`: `org.fdroid.fdroid` 1.23.2 as `system/app` (presigned, `preprocessed`)
  + `org.fdroid.fdroid.privileged` 0.2.13 as priv-app with its allow-list; `fetch-prebuilts.sh fdroid` (default set)
  pins versionCode + sha256. **Termux is not bundled**: the F-Droid APK is v2-only-signed with compressed JNI libs, so
  Soong can neither store the libs (breaks the signature) nor ship it verbatim (system apps get no lib extraction →
  `UnsatisfiedLinkError`). Install Termux from the bundled F-Droid (same signer as the one it ships). The GitHub-signed
  copy from 2026-10-05 survived the update in /data, and F-Droid cannot update it (different signer) — uninstall it, then
  install from F-Droid when wanted.
- **AOHP Driver 0.5.0** (`injinj/aohp-driver` `d8cfb1f`, tag `v0.5.0`, CI APK sha `89ab5224…` — byte-identical to the
  local build; vendor/aohp `00ae840` pins it): **Autostart is on by default**; the Runtime-card switch is now an opt-out
  (`autostart_off_envs`). Envs that were already on are unaffected; an env that was explicitly off becomes on. Verified on both
  phones: zero touches after boot → bridge, env-start (sshd, net-watchdog.timer), gateway `/health` live.
  **directBootAware not done** — `BOOT_COMPLETED` is still withheld while a lock-screen PIN keeps user 0
  `RUNNING_LOCKED`; doing it properly needs DE-storage prefs and a gateway deferral to `ACTION_USER_UNLOCKED` (the
  Keystore secret is CE-bound), so "no PIN on headless AOHP phones" stays the rule.

## Queued for a later build — 2026-10-06 (re-queued after the flash)

- **dodge build-5: freeform feature XML** — vendor/aohp `36d33ea`, **in progress** (building 2026-10-06); after the flash confirm
  the dock gives a desk with no `settings put` (drop the runtime `enable_freeform_support` workaround) and release it. Decide afterwards whether the `persist.wm.debug.desktop_experience_devopts` property should stay
  baked in or only the overlay.
- **Recovery adb key path**: make `aohp_adb_keys_recovery` land at `/adb_keys` in the recovery ramdisk (replace the
  `create_root_structure.mk` symlink in the recovery variant), so recovery adb is key-authorized and the post-sideload
  `adb reboot` works without a tap.
- **TUN** still open (below).
- **Driver directBootAware** (see above): bridge + env-start on `LOCKED_BOOT_COMPLETED` with device-protected prefs,
  gateway start on `ACTION_USER_UNLOCKED`.
- **TUN probe** (see above): if the C probe also gets EPERM with NET_ADMIN effective and no `avc:`, look at the kernel
  (`tun_set_iff` → `ns_capable(net->user_ns, CAP_NET_ADMIN)`) and the user-ns of the container process rather than at
  sepolicy; until then `tailscaled --tun=userspace-networking`.
- **Termux** stays an F-Droid install (above). Re-check if a future F-Droid build ships a v1 signature or stored libs.
- `aohp-update` must run `install/units.sh` (docs already say it does); ship the `aohp` CLI (feat/units) as an aohp-agents
  release asset — it is too large for the binder base64 file push. (aohp-agents template work, not ROM.)
- Template `sshd.service`: use `-D -e` instead of `-E <file>` so `journalctl -u sshd` shows output; drop the
  `LD_PRELOAD=libnoaudit.so` line (build-6/dodge-4 are on the phones; both envs already have it removed by hand).
- Pixel 6 gateway cold start is 52–71 s vs 10 s on the OnePlus 13 with the same unit/template — investigate.
- Unit `Main PID` is the `sh -c` wrapper; consider `exec` in the wrapper or direct spawn when `ExecStart` has no shell syntax.
