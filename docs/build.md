# Building LineageOS 23.2 + AOHP from source

Everything below was run on `chex` (Fedora, 32 threads, 123 GB RAM) on 2026-10-03/04; the commands are the ones from
the build scripts, not a transcription of the wiki. Disk: ~65 GB `.repo`, ~91 GB working tree, 43 GB `out/` for dodge
(incl. the in-tree kernel), ~15 GB for oriole; plus the kernel tree `out-kernel/` for oriole (22 GB).

## 1. Sync the tree

```bash
mkdir -p ~/lineage/android && cd ~/lineage/android
repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs --no-clone-bundle --partial-clone --clone-filter=blob:limit=10M
mkdir -p .repo/local_manifests
curl -fsSL https://raw.githubusercontent.com/injinj/local_manifests/lineage-23.2-aohp/aohp.xml -o .repo/local_manifests/aohp.xml
repo sync -c -j8 --no-tags --no-clone-bundle --optimized-fetch --prune --retry-fetches=3
```

- The partial-clone flags work with Lineage's manifest (61 min for the base tree on a fast link; the 5.5 GB
  `android_frameworks_base` pack dominates). The dodge additions synced in 6 min.
- `vendor/aohp` is a **private** repo: `repo sync` needs a GitHub credential with access to the injinj account
  (`gh auth login` + `gh auth setup-git`, or a `~/.git-credentials` entry). Everything else is public.
- The manifest replaces four LineageOS platform projects (`build/make`, `system/core`, `system/sepolicy`,
  `frameworks/base`) with the injinj `lineage-23.2-aohp` branches and adds the Pixel 6 / OnePlus 13 device trees,
  kernels and TheMuppets vendor repos. No `roomservice` additions are needed (`breakfast` found everything present).

## 2. Fetch the prebuilts that are not in git

```bash
vendor/aohp/fetch-prebuilts.sh            # Debian template (pinned TEMPLATES_TAG, currently templates-20261005b) + AOHPDriver.apk (v0.3.0) + OpenClawAndroid.apk + stock prebuilts, all sha256-verified
# vendor/aohp/fetch-prebuilts.sh fedora arch   # optional extra templates; aohp.mk enables them when the file exists
```

This writes `packages/apps/AOHPAgentDriver/rootfs/debian.tar.gz` (from the newest
[aohp-agents `templates-*` release](https://github.com/injinj/aohp-agents/releases)),
`packages/apps/AOHPDriver/{Android.bp,AOHPDriver.apk,initial-package-stopped-states-aohp.xml}` and
`packages/apps/OpenClawAndroid/{Android.bp,OpenClawAndroid.apk}` (from the
[aohp-driver](https://github.com/injinj/aohp-driver/releases) and
[openclaw](https://github.com/injinj/openclaw/releases/tag/android-aohp-2026.8.2) releases pinned at the top of the
script). The two `packages/apps/*` dirs are not repo projects, so the script creates them.

The `stock` part fetches `packages/apps/AOHPAgentDriver/AOHPAgentDriver.apk` and `rootfs/alpine.tar.gz` from the
[injinj/AOHPAgentDriver `prebuilts-20261005` release](https://github.com/injinj/AOHPAgentDriver/releases/tag/prebuilts-20261005).
Neither is installed on the phones (only `aohp-rootfs-debian` is in `PRODUCT_PACKAGES`; `AOHPAgentDriver` /
`aohp-rootfs-alpine` belong to the Cuttlefish product), but Soong resolves every module's `apk`/`src` at analysis time,
so a checkout without the files fails at `m`. Every fetched file is sha256-pinned (templates/stock via the release's
`SHA256SUMS`, APKs via variables at the top of the script); a differing existing file is kept as `<file>.bak-<date>`.
Tags recorded in `rootfs/.templates-release`, `rootfs/.stock-release`, `AOHPDriver/.apks-release`.

## 3. Build

```bash
cd ~/lineage/android
export WITH_ADB_INSECURE=true      # see below
source build/envsetup.sh

# Pixel 6
breakfast oriole                   # = lunch lineage_oriole-bp4a-userdebug + build_kernel: repo-inits/syncs
                                   #   android_kernel_google_gs-6.1_manifest (lineage-23.2) into out-kernel/google/gs-6.1
                                   #   and runs the Kleaf build_raviole.sh (~10 min; the GKI core is prebuilt there)
m -j10 bacon                       # -> out/target/product/oriole/lineage-23.2-<date>-UNOFFICIAL-oriole.zip, boot.img, dtbo.img, vendor_boot.img, vbmeta.img

# OnePlus 13
breakfast dodge                    # lineage_dodge-bp4a-userdebug; kernel 6.6 built in-tree (INLINE_KERNEL_BUILDING,
                                   #   kernel/oneplus/sm8750 + ~50 TARGET_KERNEL_EXT_MODULES from sm8750-modules)
m -j10 bacon                       # -> out/target/product/dodge/lineage-23.2-<date>-UNOFFICIAL-dodge.zip, boot/dtbo/init_boot/vbmeta/vendor_boot/recovery.img
```

`brunch oriole` / `brunch dodge` is the one-step equivalent of `breakfast` + `m bacon`.

**`WITH_ADB_INSECURE=true`** is Lineage's own knob (`vendor/lineage/config/common.mk`): without it a userdebug build
gets `ro.adb.secure=1` and `PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG` (→ `ro.debuggable=0`), adb is off at first boot, the
RSA prompt appears, and **the Lineage recovery (same props, vendor_boot ramdisk) refuses adb** — which is how the first
Pixel flash attempt got stuck in recovery with `unauthorized`. With it, `ro.adb.secure=0` and
`post_process_props.py` auto-adds `persist.sys.usb.config=adb`; `vendor/aohp/aohp.mk` adds the latter to the product
partition as well. It must be in the environment before `breakfast` (evaluated when `common.mk` is parsed, before
`aohp.mk` is inherited — it cannot be set from `aohp.mk`). `adb root` additionally needs *Developer options → Rooted
debugging* on the phone (Lineage's `adbroot_service`), which is not needed for AOHP work (`aohp sandbox exec` is root
inside the env).

### Build times on chex (`-j10`, systemd `CPUQuota=1000%`, no ccache)

| | time | notes |
|---|---|---|
| oriole, cold | 2 h 31 min to the sepolicy failure at 92 % (first attempt), then 11 min incremental | 219k ninja actions |
| oriole, prop change (build 3) | 5 min | |
| dodge, cold incl. kernel + DLKMs | **1 h 53 min** | 133k actions, peak 49.6 GB RAM, `KERNEL_OBJ` 2.5 GB |
| `m -j10 systemimage` after an app/template change | 1–2 min | |

Run long builds detached (`systemd-run --user --unit=lineage-build --collect -p CPUQuota=1000% -p Nice=10 bash -c '… > build.log 2>&1'`)
and poll the log; a terminal session that dies takes the build with it.

### Things that bit

- **`sepolicy_freeze_test`**: Lineage 23.2 builds with `TARGET_RELEASE=bp4a` and a frozen vendor API, so any new type in
  `system/sepolicy/public/` fails the build ("The following public types were added: aohp_container_socket"). The AOHP
  GSI used `trunk_staging` where the test is a no-op. Fix in the sepolicy branch: `aohp_container_socket` lives in
  `private/file.te`. No other sepolicy change was needed for either phone.
- **`policycap functionfs_seclabel`**: the OnePlus GSI needed it dropped (its stock 6.6 kernel rejected it). Lineage's
  own `lineage-23.2` sepolicy carries the policycap and its dodge kernel (6.6.142, built here) accepts it — so the patch
  is intentionally **not** applied; verified by the dodge first boot (enforcing, no init loop).
- **`manifest_check`** fails on any `<uses-library>` mismatch between an imported APK and its `Android.bp`: the Driver
  declares none (→ no `optional_uses_libs`); the OpenClaw app declares `androidx.window.extensions` /
  `androidx.window.sidecar` as not-required (→ listed in `optional_uses_libs`). Check with
  `aapt dump badging <apk> | grep uses-library` after any APK bump.
- A new system app is *stopped* until first launch and gets no `BOOT_COMPLETED`; the Driver is exempted by
  `initial-package-stopped-states-aohp.xml` (sysconfig). Verified with a fresh secondary user.
- Soong resolves `prebuilt_etc.src` for every module at analysis time, so an optional template module whose tarball is
  absent breaks *every* build — the fedora/arch modules are `soong_config`-gated and disabled unless `aohp.mk` sees the file.
- Lineage's default dev platform key (`build/make/target/product/security/platform.*`) is byte-identical to the AOHP
  tree's, so the platform-signed Driver keeps its signature with no `PRODUCT_DEFAULT_DEV_CERTIFICATE` override.

## 4. Verify the artifacts

`sha256sum` the zip and images and keep the list (the releases' `SHA256SUMS` were produced this way). Useful checks on
the zip: `unzip -p <zip> META-INF/com/android/metadata` (`ota-type=AB`, `pre-device`, `post-build`), and
`unzip -l <zip> | grep -E 'aohp|AOHPDriver|OpenClawAndroid'` is not possible for a payload OTA — inspect
`out/target/product/<device>/system/` instead (`system/app/AOHPDriver`, `system/app/OpenClawAndroid`,
`system/bin/aohp-containerd`, `system/etc/aohp/`, `system/etc/sysconfig/initial-package-stopped-states-aohp.xml`) and
`system_ext/etc/build.prop` for `ro.adb.secure=0`.

## 5. Publishing a build

- Zip ≤ 2 GiB (oriole, 1.98 GB): upload as-is. Zip > 2 GiB (dodge, 3.76 GB): `split -b 1900M -d -a 1 <zip> <zip>.part`
  and publish the parts + a `SHA256SUMS` that lists the whole zip and each part (see the dodge release).
- `gh release create <tag> --repo injinj/aohp-lineage --target main --notes-file notes.md SHA256SUMS *.img <zip or parts>`,
  detached (a 3.8 GB upload takes a while); verify with `gh release view <tag> --json assets` that the sizes match.
