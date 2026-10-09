# GPU and a display for Linux apps inside the env (OnePlus 13, dodge build-15, 2026-10-09)

Native GL apps in the Debian env render on the Adreno 830 through Mesa turnip/freedreno opened directly on
`/dev/kgsl-3d0`, and present into a **Termux:X11** window whose X server is started and supervised by
aohp-containerd as a [`HostExec=` unit](units.md#hostexec--units-that-run-on-the-android-side-dodge-build-8-2026-10-09).
Everything below runs with SELinux **enforcing**; no `su`, no adb, no VM. Verified: `glxgears` 60 FPS vsynced on the
phone panel (120 FPS uncapped), a LÖVE game as a unit visible in the Termux:X11 window after a cold boot.

The WSL analogy holds piece by piece: the env is the distro, containerd is the WSL service, `HostExec=` is interop
(the distro asks the host to run something only the host can), and Termux:X11 is WSLg's X server — ours lives in an
app window instead of a RAIL compositor.

## What the ROM provides

All in `system/sepolicy` `private/aohp_container_daemon.te` on `injinj/android_system_sepolicy` `lineage-23.2-aohp`
(`a16b6131c` … `4a0ef855c`) plus `aohp-containerd` `HostExec=` on `injinj/platform_system_core` (`340e034a4`, `da7e20695`).

| for | rules (domain `aohp_container_daemon` unless noted) |
|---|---|
| Mesa on KGSL | `gpu_device` chr_file rw + dir r, `sysfs_gpu` file r |
| X11 window buffers | `dmabuf_heap_device` dir r, `dmabuf_system_heap_device` chr_file r (`/dev/dma_heap/system`) |
| running `app_process` (the X server) in the daemon domain | `shell_exec` + `zygote_exec` rx; `apk_data_file` dir r + file **`{ r_file_perms execute }`** (libXlorie.so is mmap'd straight from base.apk — without `execute` the process is SIGKILLed in ~80 ms); `dalvikcache_data_file` r; `apex_info_file` r, `apex_module_data_file` search + `apex_art_data_file` r, `vendor_apex_file` r; `mnt_expand_file` getattr; `userfaultfd_use` (ART GC); JIT memfd (`tmpfs_domain` + `_tmpfs:file execute`); `get_prop` odsign / build_attestation / lcd-density |
| talking to the system | `binder_use`, `binder_call` → surfaceflinger + system_server, `hal_client_domain hal_graphics_allocator` (+ fd use), `service_manager find` for surfaceflinger/display/activity/package, surfaceflinger `unix_stream_socket` rw |
| the Termux:X11 Activity ↔ X server handoff | `binder_call(untrusted_app_all, aohp_container_daemon)`; **`allow untrusted_app_all aohp_container_daemon:fd use`**, `:unix_stream_socket { read write getattr getopt setopt shutdown }`, `:fifo_file { read write getattr }` — the app calls `getXConnection()` / `getLogcatOutput()` on the server's IBinder and the *reply* carries ParcelFileDescriptors created in the daemon domain |

Not changed, by design: vendor policy (dodge keeps the OEM vendor image — a rule in `device/qcom/sepolicy_vndr` never
ships; the `vendor_sysfs_kgsl` symlink denial is harmless), `vendor_overlay_file` (coredomain neverallow; the stat
stays denied), and no `sys_ptrace`.

## Env preparation (Debian trixie, survives ROM updates)

1. `apt install libgl1-mesa-dri mesa-libgallium libegl-mesa0 libglx-mesa0 libegl1 libgl1 libgles2 mesa-vulkan-drivers libvulkan1 vulkan-tools mesa-utils xkb-data x11-xkb-utils x11-xserver-utils`
2. Debian's Mesa 25.0.7 has neither the A830 entries nor the KGSL backend (`-Dfreedreno-kmds` defaults to `msm`). Extract the
   [lfdevs/mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container) trixie-arm64 tarball
   (26.3.0-devel, built with `msm,kgsl`) over `/` and run `ldconfig`. It adds `dri/kgsl_dri.so`, `libvulkan_freedreno.so`
   and the ICD beside Debian's files.
3. Check without a display: `vulkaninfo --summary` lists `Turnip Adreno (TM) 830`; `MESA_LOADER_DRIVER_OVERRIDE=kgsl eglinfo -B -p surfaceless` says `freedreno … OpenGL 4.6`.
4. Display: install Termux:X11 separately (GPL-3, not shipped in the ROM): `gh release download nightly -R termux/termux-x11 -p termux-x11-universal-debug.apk` → `adb install -r -g`.
5. Units: `/etc/aohp/x11.env` with `DISPLAY=:0 XDG_RUNTIME_DIR=/tmp MESA_LOADER_DRIVER_OVERRIDE=kgsl`, the `x11.service`
   from [units.md](units.md) and app units that `Requires=x11.service`. `systemctl start love-bounce` (or `aohp unit oc start …`)
   brings up the X server, then the app. Open the Termux:X11 app once to see the surface; the server keeps running when the
   window is closed, and `Restart=on-failure` brings it back if it dies.

## Known gaps

- **Vulkan on-screen** (`vkcube`) asserts in `demo_prepare_buffers`: presentation needs the non-legacy AHB path
  (drop `-legacy-drawing` on the X server) plus gralloc rules. Off-screen Vulkan (`vulkaninfo`, compute) works.
- `zink` needs `/dev/shm`; the env has none (no SysV IPC in the GKI kernel either).
- No window manager by default — each client fills the phone screen. Add `openbox.service` (`Requires=x11.service`) when docked.
- Template units (`name@.service`) are not supported by the unit manager.
- Pixel 6 (Mali G78, no open userspace): planned as a host-side `virgl_test_server` proxy on the vendor EGL with
  `GALLIUM_DRIVER=virpipe` in the env; not built.

## Debugging an X server (or any `app_process`) unit that dies under enforcing

1. `adb shell logcat -d -s AndroidRuntime:E` first — a Java uncaught exception (e.g. `UnsatisfiedLinkError` from a
   library the domain may not `execute`) is turned into SIGKILL by Android's handler and shows as `Killed` / rc 137 with
   no AVC in logcat.
2. `adb shell dmesg | grep avc | grep aohp_container_daemon` — **dmesg, not logcat**, is the complete AVC source.
3. Binder `DeadObjectException` ("remote process probably died") while the remote is alive = the kernel refused the
   transaction. `adb root; cat /dev/binderfs/binder_logs/failed_transaction_log`: `reply from <server> to <app> … ret 29201/-1`
   is BR_FAILED_REPLY / EPERM = a sepolicy rule on the fd or binder object in the reply. The AVC is logged once under the
   binder thread's comm (`binder:<pid>_2`), so grep by `scontext=`/`tcontext=`, not by process name.
4. One short permissive run (`setenforce 0; systemctl start x11; setenforce 1`) harvests the whole remaining AVC set from
   `dmesg` in one go — cheaper than one rebuild per denial. The units and the gateway keep running through it.
5. A screenshot is evidence only when `dumpsys window | grep mCurrentFocus` names `com.termux.x11`: wake with
   `input keyevent 26` (POWER — `KEYCODE_WAKEUP` is refused while the proximity sensor is covered), swipe to unlock,
   `am start -n com.termux.x11/.MainActivity`, then `screencap`.
