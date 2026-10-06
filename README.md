# LineageOS 23.2 + AOHP

**LineageOS 23.2 (Android 16) with the [AOHP](https://github.com/aohp-os/aohp) agent harness built in**, for the
**Pixel 6 (`oriole`)** and the **OnePlus 13 (`dodge`, CPH2655)**. The ROM ships `aohp-containerd` + the AOHP framework
services, the **AOHP Driver** app (host console + agent bridge), the **OpenClaw Android** app (chat client) and a Debian
agent-container template, so a phone runs an OpenClaw gateway *on the device* inside a container, and the OpenClaw app
pairs with it over loopback. Both builds were flashed and verified on real phones on 2026-10-04 (SELinux enforcing,
gateway live, app paired, test message answered).

This repository is the **documentation + ROM release host**. Code lives in the repos listed below.

| | |
|---|---|
| **ROM releases** | [Releases page](https://github.com/injinj/aohp-lineage/releases) - tags are `oriole-<lineage>-<date>-build<N>` (Pixel 6) and `dodge-<lineage>-<date>-build<N>` (OnePlus 13); the newest tag per device is the current build, and each release note says what changed and which build it supersedes. |
| Build from source | [docs/build.md](docs/build.md) |
| Install from a release | [docs/install-oriole.md](docs/install-oriole.md) · [docs/install-dodge.md](docs/install-dodge.md) |
| First boot, provisioning the agent container, pairing the app | [docs/provisioning.md](docs/provisioning.md) |
| Units: systemd-style services, timers, `systemctl` shim | [docs/units.md](docs/units.md) |
| Known issues | [docs/known-issues.md](docs/known-issues.md) |

> These are **development builds**: `userdebug`. Since oriole build-6 / dodge build-4 (2026-10-06) adb is key-authorized
> (`ro.adb.secure=1`; the build host's key is baked in, other hosts get the RSA prompt) and `adb root` works on request
> (userdebug adbd; Lineage's *Rooted debugging* toggle keeps it root across boots). Earlier builds used `WITH_ADB_INSECURE=true`
> (no authorization at all, also in recovery). Do not use them on a phone that
> holds anything you care about. The dodge zip contains OnePlus proprietary vendor blobs (TheMuppets), which is why this
> repository is private for now.

## What is in the ROM

| component | where | from |
|---|---|---|
| AOHP framework: `aohp_container`, `aohp_virtual_display`, `aohp_agent_view`, `aohp_event_stream`, `aohp_file_bridge`, `aohp_security_bridge`, `aohp_ad`, `aohp_vault`, `aohp_taint`, … services; `ro.aohp.virtual_display_policy=true` | system_server, product build.prop | frameworks/base + build/make patches (aohp-os upstream squash + injinj commits) |
| `aohp-containerd` (chroot container runtime, host netns; since build-5/build-3 also the **unit manager**: systemd-subset units from the container's `/etc/aohp/system`, restart policy, ordering, timers, `UNIT` socket op) + `aohp-containerd.rc`, `/system/etc/aohp/cgroup.conf` | `/system/bin`, `/system/etc/init` | system/core patches (`aohp-containerd/`) |
| sepolicy: `aohp_container_daemon`, `aohp_container_socket` (private policy, see build notes), `aohp_agent_app.te`; since build-4/build-2: `netlink_audit_socket` (sshd/PAM/sudo), `proc_*` reads, io_uring, FICLONE/FS_IOC ioctls, `sysfs_dm` reads | plat_sepolicy.cil | system/sepolicy patches |
| **AOHP Driver** `org.aohp.driver` 0.5.0 — Runtime / Harness / Terminal / Web tabs, hosts the agent bridge (`ws://127.0.0.1:6666` JSON-RPC for the `aohp` CLI, incl. `sandbox.unit`), Keystore-backed secrets, **Units card** per env, boot autostart = **env-start** (enabled units in dependency order; 0.3.0-style replay of recorded services for envs without units), first-run wizard | `/system/app/AOHPDriver`, platform-signed, not privileged | [injinj/aohp-driver](https://github.com/injinj/aohp-driver) — [release v0.4.0](https://github.com/injinj/aohp-driver/releases/tag/v0.4.0) (built by GitHub Actions) |
| **OpenClaw Android** `ai.openclaw.app` 2026.8.2 (thirdParty release) | `/system/app/OpenClawAndroid`, presigned with the injinj `aohp-apps` key | [injinj/openclaw release android-aohp-2026.8.2](https://github.com/injinj/openclaw/releases/tag/android-aohp-2026.8.2) |
| Debian trixie agent template (Node 24, OpenClaw, `aohp` CLI with `unit`/`timer`, gcc, python, gh, age, aohp-agents layer; wireguard-tools + openssh-server installed but inactive, `/opt/aohp-agents/net/` kit; since templates-20261005c: unit files in `/etc/aohp/system` (`openclaw-gateway.service` enabled) + `systemctl`/`journalctl` shims) | `/system/etc/aohp/rootfs-templates/debian.tar.gz` | [injinj/aohp-agents templates-20261005c](https://github.com/injinj/aohp-agents/releases/tag/templates-20261005c) (Dockerfiles in `template/`); build-4/build-2 carried templates-20261005b, the 2026-10-04 builds the hand-built 617 MB predecessor |
| `initial-package-stopped-states-aohp.xml` — the Driver is not "stopped" on first boot, so it receives `BOOT_COMPLETED` and the bridge + gateway come up before anyone opens the app | `/system/etc/sysconfig` | aohp-driver `aosp/` |

## Repository map

All platform/device branches are called `lineage-23.2-aohp` = LineageOS `lineage-23.2` + the aohp-os upstream squash + injinj commits.

| repo | role |
|---|---|
| [injinj/local_manifests](https://github.com/injinj/local_manifests/tree/lineage-23.2-aohp) (`aohp.xml`, `README-lineage.md`) | the local manifest that turns a stock `lineage-23.2` `repo init` into this tree |
| [injinj/android_build](https://github.com/injinj/android_build/tree/lineage-23.2-aohp) | build/make — AOHP product bits (replaces `LineageOS/android_build`) |
| [injinj/platform_system_core](https://github.com/injinj/platform_system_core/tree/lineage-23.2-aohp) | system/core — `aohp-containerd` (branch on the existing aohp-os fork: GitHub allows one fork per network) |
| [injinj/android_system_sepolicy](https://github.com/injinj/android_system_sepolicy/tree/lineage-23.2-aohp) | system/sepolicy — AOHP policy; `aohp_container_socket` moved to private policy for `sepolicy_freeze_test` |
| [injinj/android_frameworks_base](https://github.com/injinj/android_frameworks_base/tree/lineage-23.2-aohp) | frameworks/base — AOHP services, AIDL in `core/java/com/android/internal/aohp/` |
| [injinj/android_device_google_raviole](https://github.com/injinj/android_device_google_raviole/tree/lineage-23.2-aohp) | Pixel 6 family: `lineage_oriole.mk` inherits `vendor/aohp/aohp.mk` (+3 lines) |
| [injinj/android_device_oneplus_dodge](https://github.com/injinj/android_device_oneplus_dodge/tree/lineage-23.2-aohp) | OnePlus 13: `lineage_dodge.mk` inherits `vendor/aohp/aohp.mk` (+3 lines) |
| [injinj/android_vendor_aohp](https://github.com/injinj/android_vendor_aohp) (private) | `vendor/aohp/aohp.mk` (PRODUCT_PACKAGES, allow-list, props) and `fetch-prebuilts.sh` (templates + APKs, sha256-pinned) |
| [injinj/AOHPAgentDriver](https://github.com/injinj/AOHPAgentDriver) (`injinj-main`) | `packages/apps/AOHPAgentDriver`: Android.bp for the `aohp-rootfs-*` template modules (the stock demo app itself is **not** shipped) |
| [injinj/aohp-driver](https://github.com/injinj/aohp-driver) | the AOHP Driver app (Kotlin/Compose), its `aosp/` Android.bp files, `.github/workflows/release.yml` |
| [injinj/aohp-agents](https://github.com/injinj/aohp-agents) | container templates (`template/`), `bootstrap.sh` / `aohp-bootstrap`, `aohp-secrets`, installers |
| [injinj/openclaw](https://github.com/injinj/openclaw) | OpenClaw fork; hosts the signed Android APK release |
| [injinj/aohp](https://github.com/injinj/aohp) (`feat/units`, on top of `feat/cli-secret`) | the `aohp` CLI with `secret get/set/list` and `unit`/`timer` (upstream PR pending) |

## Quick start (install a release)

1. Unlock the bootloader and bring the phone to the stock firmware level the LineageOS wiki requires
   ([oriole](https://wiki.lineageos.org/devices/oriole/install/), [dodge](https://wiki.lineageos.org/devices/dodge/install/)).
2. Download the device's release assets, `sha256sum -c SHA256SUMS` (dodge: `cat …zip.part0 …zip.part1 > …zip` first).
3. Follow [docs/install-oriole.md](docs/install-oriole.md) or [docs/install-dodge.md](docs/install-dodge.md): fastboot the
   boot images → Lineage recovery → factory reset → `adb sideload <zip>` → reboot.
4. First boot: adb is on, no prompt; `aohp-containerd` and the Driver bridge are already running. Continue with
   [docs/provisioning.md](docs/provisioning.md) to create the agent container, provision OpenClaw and pair the app.

## Credits and licenses

- [LineageOS](https://lineageos.org/) — the ROM, device trees and kernels (Apache-2.0 / GPL-2.0 as per project).
- [AOHP — Android Open Harness Project](https://github.com/aohp-os) (`aohp-os/aohp`, `platform_frameworks_base`,
  `platform_system_core`, `platform_system_sepolicy`, `platform_build`) — the agent harness (Apache-2.0). The injinj
  branches carry its patch set; fixes are being upstreamed as PRs.
- [TheMuppets](https://github.com/TheMuppets) — proprietary vendor blobs for oriole and dodge (device vendors' licenses).
- [OpenClaw](https://github.com/openclaw/openclaw) — gateway and Android app (see upstream LICENSE).
- Debian / Node.js / the packages inside the container template — their respective licenses.
- Nothing here is affiliated with or endorsed by LineageOS, Google, OnePlus or the AOHP project.
