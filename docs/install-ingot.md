# Install on the Solana Saga (ingot, OSOM) from a release

Release: **[ingot-23.2-20261018-build1](https://github.com/injinj/aohp-lineage/releases/tag/ingot-23.2-20261018-build1)**.
This is the sequence that was actually run on 2026-10-17 (the first AOHP build for this device), following the
[LineageOS install wiki for ingot](https://wiki.lineageos.org/devices/ingot/install/) with the deviations noted.
The Saga is an **official LineageOS device**, so the wiki is authoritative for anything not covered here.

## Prerequisites

- **Stock Android 14 firmware first.** LineageOS 23.2 for ingot requires the vendor/bootloader/modem from the stock
  Android 14 build (the device tree is keyed to `OSOM/ingot/ingot:14/UKQ1.240227.165`). A Saga as shipped is on
  Android 13 (build 468). Take the OSOM OTA from the stock **Settings → System update** until it offers nothing
  newer, and boot it once — do this *before* unlocking, while the stock updater is still there. Skipping this is
  the wiki's "failure to install / crashes post-install" case.
- **Unlocked bootloader.** *Settings → Developer options → OEM unlocking* on, every Google account removed
  (factory-reset protection), then the unlock step below. Unlocking **wipes the phone**.
- Host: `adb` and `fastboot` (platform-tools 35+; the Lineage tree's `out/host/linux-x86/bin/fastboot` 36.0.1 was
  used), USB-C cable. The phone enumerates as `18d1:d00d` in fastboot and `18d1:d001` in recovery. Commands below
  used `-s O1N1XT272300327` (the test phone's serial) — drop it if only one device is attached.
- Download `lineage-23.2-20261018-UNOFFICIAL-ingot.zip`, `boot.img`, `dtbo.img`, `vbmeta.img`, `vendor_boot.img`,
  `recovery.img`, `SHA256SUMS` and verify: `sha256sum -c SHA256SUMS`. The zip is 1.84 GB, a single file (no parts
  to reassemble). Whole-zip sha256 `f9355848b8e37abb69275954a79e00cc831db0e4b573b4a66a5da4a9895d4222`.

**Everything on the phone is wiped** — once by the unlock, once more by the mandatory format in recovery.

## Unlock

```bash
adb -s O1N1XT272300327 shell getprop sys.oem_unlock_allowed   # 1 after the Developer-options toggle
adb -s O1N1XT272300327 reboot bootloader
fastboot -s O1N1XT272300327 getvar unlocked                   # no
fastboot -s O1N1XT272300327 flashing get_unlock_ability       # 1
fastboot -s O1N1XT272300327 flashing unlock
```

On this device `flashing unlock` **returns OKAY immediately — there is no volume-key confirmation screen**. The
phone drops off USB, wipes, and reboots into the stock setup wizard. Walk the wizard far enough to reach Settings,
re-enable *Developer options → USB debugging* (accept the host key), then:

```bash
adb -s O1N1XT272300327 reboot bootloader
fastboot -s O1N1XT272300327 getvar unlocked                   # yes
fastboot -s O1N1XT272300327 getvar current-slot               # a or b; the flashes below go to that slot
```

## Flash

```bash
# boot chain for the current slot (the bootloader resolves the _a/_b suffix itself)
fastboot -s O1N1XT272300327 flash boot boot.img
fastboot -s O1N1XT272300327 flash dtbo dtbo.img
fastboot -s O1N1XT272300327 flash vbmeta vbmeta.img
fastboot -s O1N1XT272300327 flash vendor_boot vendor_boot.img
fastboot -s O1N1XT272300327 flash recovery recovery.img

# into Lineage recovery
fastboot -s O1N1XT272300327 reboot recovery
```

### Trap: `fastboot reboot recovery` may boot the system instead

On the first attempt the phone ignored the recovery request, sat on the **OSOM splash** and never enumerated on USB
(no adb, no fastboot — not in recovery, hung in an early system boot with the just-flashed vendor_boot and the
stock system). Recovery: **hold Power ~15 s** until it goes dark, then **Volume Down + Power** into the bootloader,
`fastboot -s O1N1XT272300327 reboot recovery` again — the second request was honoured. If it still boots the
system, pick *Recovery Mode* from the bootloader menu with the volume keys instead.

## Install from recovery

The phone shows the LineageOS recovery (`adb devices` → `recovery`). Two steps on the phone's screen (volume keys
to move, power to select):

1. **Factory Reset → Format data / factory reset** — confirm. Mandatory on a first install (removes the stock
   encryption; the data partition is recreated on first boot).
2. **Apply update → Apply from ADB.**

Then from the host:

```bash
adb -s O1N1XT272300327 sideload lineage-23.2-20261018-UNOFFICIAL-ingot.zip
```

The host's progress counter parks at **~47 %** while `update_engine` applies the A/B payload to the other slot —
watch the phone's own progress bar, not the host. It ends with `Total xfer: 1.00x` on the host and a "done"
message on the phone. Then **Reboot system now** (or `adb -s O1N1XT272300327 reboot`).

## First boot

- Boots into the other slot (A/B OTA; the payload carries boot/dtbo/vendor_boot/vbmeta for that slot). Allow a
  couple of minutes for the first boot.
- The bootloader shows the unlocked-device warning on every boot — expected.
- **adb is on immediately for the build host**: the image sets `persist.sys.usb.config=adb` and carries the chex adb
  public key, so there is no "Allow USB debugging?" dialog for that host. `ro.adb.secure=1`, so any other host gets
  the usual one-time dialog on the phone.
- Verify:
  ```bash
  adb -s O1N1XT272300327 shell getprop ro.lineage.version         # 23.2-20261018-UNOFFICIAL-ingot
  adb -s O1N1XT272300327 shell getenforce                         # Enforcing
  adb -s O1N1XT272300327 shell pm list packages | grep -E 'aohp|openclaw'   # org.aohp.driver, ai.openclaw.app
  adb -s O1N1XT272300327 shell ps -A | grep aohp-containerd       # running as root
  adb -s O1N1XT272300327 shell ss -ltnp | grep 6666               # 127.0.0.1:6666, org.aohp.driver (bridge up without opening the app)
  adb -s O1N1XT272300327 shell 'logcat -d -b all | grep -c "avc: *denied"'   # 0 AOHP denials on the test phone
  ```
- The Lineage setup wizard runs on the screen (language, Wi-Fi, lock screen). No GApps are included.
- `adb root` says *"ADB Root access is disabled by system setting"* until *Developer options → Rooted debugging* is
  enabled. The agent container does not need it (`aohp sandbox exec` is root inside the env); provisioning via
  `adb shell chroot` does.

Continue with [provisioning.md](provisioning.md). Two traps met while provisioning the `oc` env on this phone on
2026-10-17 (they apply to any device, this was just where they were found):

- A raw `chroot /data/aohp/envs/<env>/rootfs` from `adb shell` has an **empty `/dev`** — `git` dies with
  `unable to get random bytes`. Bind-mount `/dev /dev/pts /proc /sys` into the rootfs for the session and `umount -l`
  them afterwards.
- **Remove those bind mounts before starting any unit.** A unit started while they are in place gets no `devpts`
  (containerd's `newinstance` devpts mount lands on the host-namespace bind): sshd logs `openpty: No such device`,
  interactive `ssh` closes while `ssh host cmd` works. Fix: `umount -l` the binds, then `systemctl restart sshd`
  (and the gateway) inside the env. Rule: provision in the chroot, start units through `aohp sandbox exec` or the
  Driver.

## Updating to a later build

Later ingot releases are data-preserving sideload updates — no fastboot, no format:

```bash
adb -s O1N1XT272300327 reboot sideload
adb -s O1N1XT272300327 sideload lineage-23.2-<date>-UNOFFICIAL-ingot.zip
adb -s O1N1XT272300327 reboot
```

The host counter again parks at ~47 %; the phone comes back on the other slot with `/data` and the AOHP envs intact.

## Deviations from the wiki (summary)

- `fastboot flashing unlock` needed no on-phone confirmation (the wiki says "if the device doesn't automatically
  reboot, reboot it" — it rebooted on its own).
- Entered the bootloader with `adb reboot bootloader` instead of the Volume Down + Power combo (the combo is the
  fallback in the reboot-recovery trap above).
- `boot.img` is flashed alongside dtbo/vbmeta/vendor_boot/recovery (the wiki flashes only the latter four and lets
  the OTA write boot; both work — the sideloaded payload overwrites all of them for the target slot anyway).
- No GApps; no `--disable-verification` on vbmeta (the release vbmeta.img is the build's own).

## Back to stock

Not exercised. OSOM/Solana Mobile stock images are not mirrored here; the Lineage wiki's ingot page links the
vendor's restore instructions. Re-lock (`fastboot flashing lock`) only after stock boots, if at all — locking with
a non-stock vbmeta bricks the boot chain.
