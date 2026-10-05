# Install on the OnePlus 13 (dodge, CPH2655) from a release

Release: **[dodge-23.2-20261004-build1](https://github.com/injinj/aohp-lineage/releases/tag/dodge-23.2-20261004-build1)**.
This is the sequence that was actually run on 2026-10-04 22:16–22:21 (script `op13-flash.sh`, log `REPORT-op13-flash.md`
on chex), following the [LineageOS install wiki for dodge](https://wiki.lineageos.org/devices/dodge/install/) with the
deviations noted. **Zero key presses on the phone were needed.**

## Prerequisites

- Model **CPH2655** (also in the wiki's supported list: CPH2649/CPH2653/CPH2655/PJZ110). **Unlocked bootloader**
  (`fastboot flashing unlock` after *OEM unlocking*; wipes). The test phone: `unlocked:yes`, `product:sun`.
- **Stock Android 15 or 16 firmware booted at least once** (wiki requirement). The test phone had vendor Android 15
  (`OnePlus/CPH2655/OP5D55L1:16/BP2A.250605.015/…`, vendor sdk 35). The OTA zip itself carries the OnePlus firmware
  partition set (abl, xbl, modem, dsp, tz, … 46 `ab_partitions`) for the target slot.
- Host: `adb`, `fastboot` (the Lineage tree's `fastboot` 36.0.1 was used), and — for the factory-reset deviation —
  `make_f2fs` from the Lineage tree (`out/host/linux-x86/bin/make_f2fs`) or the `f2fs-tools` package. Serial used
  below: `e6d11a7c`.
- Download all assets, reassemble the zip and verify:
  ```bash
  cat lineage-23.2-20261004-UNOFFICIAL-dodge.zip.part0 lineage-23.2-20261004-UNOFFICIAL-dodge.zip.part1 > lineage-23.2-20261004-UNOFFICIAL-dodge.zip
  sha256sum -c SHA256SUMS        # zip (eaf2aa8e…), both parts, boot/dtbo/init_boot/vbmeta/vendor_boot/recovery
  ```

**Everything on the phone is wiped.**

## Two bootloaders — read before flashing

The OnePlus 13 exposes two fastboot environments; the one that flashes everything reliably reports
`max-download-size: 805306368` (`0x30000000`) in `fastboot getvar all` ("full bootloader" in our notes). After
`adb reboot bootloader` the test phone was already in it; if `fastboot getvar max-download-size` shows something else,
run `fastboot reboot bootloader` once and check again (the flash script does exactly this check before every flash block). Also: **never `fastboot flash super`**
on this device from a partial image — the stock bootloader only accepts a complete `lpmake` super image. The sideload
OTA path below never touches `super` via fastboot, which is why it is the right way in.

## Flash

```bash
adb -s e6d11a7c reboot bootloader
fastboot -s e6d11a7c devices
fastboot -s e6d11a7c getvar max-download-size            # 805306368 = full bootloader (see above)
fastboot -s e6d11a7c getvar current-slot                 # was 'a' on the test phone

# boot chain for the current slot (bootloader resolves the _a/_b suffix itself)
fastboot -s e6d11a7c flash boot boot.img
fastboot -s e6d11a7c flash dtbo dtbo.img
fastboot -s e6d11a7c flash init_boot init_boot.img
fastboot -s e6d11a7c flash vbmeta vbmeta.img
fastboot -s e6d11a7c flash vendor_boot vendor_boot.img
fastboot -s e6d11a7c reboot bootloader                   # wiki: required before recovery
fastboot -s e6d11a7c flash recovery recovery.img
```

### Factory reset — deviation: fresh f2fs images instead of `fastboot -w`

`fastboot erase userdata` **never returns on this phone** (13 min before it was killed in an earlier session) and
`fastboot -w` erases before formatting. Proven alternative: flash freshly made, empty f2fs filesystems into `userdata`
and `metadata`, sized from the partition table and with the features Lineage's fstab expects. First boot then
formats/encrypts normally (`ro.crypto.state=encrypted`).

```bash
for p in userdata metadata; do
  szhex=$(fastboot -s e6d11a7c getvar partition-size:$p 2>&1 | grep -oE '0x[0-9a-fA-F]+' | head -1)
  sz=$(( szhex )); lbl=data; [ $p = metadata ] && lbl=metadata
  make_f2fs -S $sz -f -g android -O project_quota,extra_attr,inode_checksum,sb_checksum,compression,encrypt -s 1 -l $lbl /tmp/op13-$p.img
  fastboot -s e6d11a7c flash $p /tmp/op13-$p.img          # ~90 KB sparse images, < 4 s each
done
```
(Partition sizes on the test phone: userdata `0x72F850F000`, metadata `0x4000000`.) The wiki's alternative is
*Factory Reset → Format data / factory reset* in the Lineage recovery menu.

### Recovery → sideload → reboot

```bash
fastboot -s e6d11a7c reboot recovery        # accepted by this bootloader (wiki: pick "Recovery" with the volume keys)
adb -s e6d11a7c devices                      # "recovery" after ~10 s — no authorization prompt (ro.adb.secure=0 in this build's recovery)
adb -s e6d11a7c reboot sideload              # wiki: Apply update -> Apply from ADB
adb -s e6d11a7c sideload lineage-23.2-20261004-UNOFFICIAL-dodge.zip   # 3.76 GB, 3 min 38 s; host shows ~47 % then "Total xfer: 1.00x" = OK
adb -s e6d11a7c reboot                       # once 'adb devices' says "recovery" again (wiki: Reboot system now)
```

## First boot

- `sys.boot_completed=1` **~26 s** after the reboot, on the other slot (`_b`). The bootloader's orange-state warning
  appears on each boot (unlocked). Slot a's logical partitions are deleted by the Virtual A/B install
  (`PrepareDynamicPartitionsForUpdate(delete_source=true)`) — expected; slot a is not bootable afterwards.
- **adb works at once, no dialog.** Check: `getprop ro.lineage.version` → `23.2-20261004-UNOFFICIAL-dodge`,
  `getenforce` → `Enforcing`, kernel `uname -r` → `6.6.142-4k-g4639602afa8c`, `pm list packages | grep -E 'aohp|openclaw'`,
  `aohp-containerd` running, `ss -ltnp` shows `127.0.0.1:6666` (Driver bridge) at boot.
- Radio/Wi-Fi/BT/NFC come up on the real device tree (modem baseband `Q_V1_P14`; no SIM in the test phone). The Lineage
  setup wizard runs on screen; connect Wi-Fi there.
- Expect a steady stream of `aohp_container_daemon` AVC denials in logcat once a container runs — harmless, see
  [known-issues.md](known-issues.md).
- `adb root` needs *Developer options → Rooted debugging* (not needed for AOHP).

Continue with [provisioning.md](provisioning.md).

## Deviations from the wiki (summary)

- Factory reset by flashing empty f2fs `userdata`/`metadata` images (because `fastboot erase userdata` hangs here).
- `fastboot reboot recovery` and `adb reboot sideload` instead of the on-screen menu choices (possible because this build's
  recovery has `ro.adb.secure=0`).
- Full-bootloader check before flashing.

## Back to stock

OnePlus does not publish fastboot factory images. The route used on this phone during the earlier AOHP GSI work is a
stock `super` image (complete `lpmake` image built from the stock OTA payload of the firmware you came from — CPH2655
16.0.2.403 here, kept on the build host as `super-stock.img`) plus the stock boot/init_boot/vendor_boot/dtbo/vbmeta
images, all flashed from the full bootloader, followed by the userdata/metadata reset above. Extract and keep the stock
OTA payload **before** you start; it is your way back.
