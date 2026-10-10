# gamescope on AOHP: a GPU compositor on KGSL (OnePlus 13, dodge build-18, 2026-10-09)

**Result:** Valve's gamescope runs inside the Debian env as a *Vulkan* compositor on the Adreno 830 and presents through
Termux:X11's X11 Vulkan WSI — `vkcube` spins GPU-rendered **and** GPU-composited at the panel's rate (Termux:X11 reports
~106 FPS), both as a native Wayland client and as an X11 client through gamescope's WSI layer. No root, no `/dev/dri`
render node, SELinux enforcing. This is the first compositor on this stack that is not pixman; see
[gpu.md](gpu.md#phosh-as-the-shell-env-only) for why phoc cannot be.

It needs a build from source and two small patches (below). Everything is env-side; nothing in the ROM changed.

## Why stock gamescope fails here, and the fix

turnip on `/dev/kgsl-3d0` has no DRM device, so it does not expose `VK_EXT_physical_device_drm`. gamescope copes with
that for its own rendering ("physical device has no render node", "Failed to get DRM FD from renderer" — both non-fatal
with the SDL backend), but wlroots' `wlr_renderer_init_wl_display()` **silently skips creating the `zwp_linux_dmabuf_v1`
global when the renderer has no DRM fd**. `wayland-info` on `gamescope-0` shows `wl_shm`, `wl_compositor`, `xdg_wm_base`…
and no `zwp_linux_dmabuf_v1`. Without it Mesa's Wayland WSI cannot share swapchain images, so every Vulkan client dies at
swapchain creation (`vkGetPhysicalDeviceSurfaceFormatsKHR` fails; `vkcube` asserts in `demo_init_vk_swapchain`). The
gamescope WSI layer that X11 clients use sits on the same Wayland WSI, so it dies the same way.

The GPU side was never the problem: turnip-kgsl advertises `VK_EXT_external_memory_dma_buf`,
`VK_EXT_image_drm_format_modifier` and `VK_KHR_external_memory_fd`, and dma-buf export (client) → import (gamescope)
across processes works on the KGSL/ION path.

Patch ([`examples/gamescope/gamescope-aohp.patch`](../examples/gamescope/gamescope-aohp.patch)):

1. `src/wlserver.cpp`, right after `wlr_renderer_init_wl_display()`: if `wlr_renderer_get_drm_fd()` is negative, build a
   feedback with one tranche (`target_device = 0`, formats = the renderer's `WLR_BUFFER_CAP_DMABUF` texture formats) and
   call `wlr_linux_dmabuf_v1_create(display, 3, &feedback)`. Version **3** on purpose: v4 clients expect a main
   `dev_t` to open; v3 clients only need the format/modifier list.
2. vendored wlroots `types/wlr_linux_dmabuf_v1.c`, `set_default_feedback()`: when `main_device == 0` skip
   `drmGetDeviceFromDevId()` and leave `main_device_fd = -1` (the same path wlroots already takes for split
   display/render devices, so import checks are simply not done).

Both are ~30 lines and candidates for upstream behind a "renderer without DRM device" condition.

## Building (Debian trixie arm64, in the env)

trixie has no gamescope package; trixie-backports lists one but the arm64 pool had not caught up (and bookworm's 3.11
needs wlroots 0.15). Build 3.16.24 from the Valve tree; it vendors its wlroots fork as a subproject so Debian's
`libwlroots-0.18` is untouched.

```
apt install git meson ninja-build pkg-config g++ cmake glslang-tools hwdata xwayland \
  libx11-dev libx11-xcb-dev libxdamage-dev libxcomposite-dev libxrender-dev libxext-dev libxxf86vm-dev libxtst-dev \
  libxres-dev libxmu-dev libxi-dev libxcursor-dev libxkbcommon-dev libxkbcommon-x11-dev libxrandr-dev libxfixes-dev \
  libxcb1-dev libxcb-composite0-dev libxcb-xinput-dev libxcb-render0-dev libxcb-xfixes0-dev libxcb-ewmh-dev \
  libxcb-icccm4-dev libxcb-res0-dev libxcb-present-dev libxcb-dri3-dev libxcb-randr0-dev libxcb-errors-dev \
  libxcb-cursor-dev libxcb-keysyms1-dev libxcb-shm0-dev libxcb-xkb-dev libxcb-image0-dev libxcb-render-util0-dev \
  libwayland-dev wayland-protocols libdrm-dev libvulkan-dev libsdl2-dev libliftoff-dev libdisplay-info-dev \
  libcap-dev libinput-dev libudev-dev libseat-dev libegl-dev libgles-dev libgbm-dev libpixman-1-dev libstb-dev \
  libluajit-5.1-dev libdecor-0-dev libdbus-1-dev libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libglm-dev
git clone --depth 1 --recurse-submodules --shallow-submodules -b 3.16.24 https://github.com/ValveSoftware/gamescope
cd gamescope && git apply ../gamescope-aohp.patch   # wlserver.cpp + hdmi.h + the wlroots subproject hunk
meson setup build -Dbuildtype=release -Dpipewire=disabled -Davif_screenshots=disabled -Dinput_emulation=disabled \
  -Denable_openvr_support=false -Drt_cap=disabled -Dbenchmark=disabled -Denable_tests=false -Dwerror=false
ninja -C build -j6          # ~20 min on the OnePlus 13
install -m755 build/src/gamescope build/src/gamescopereaper build/src/gamescopectl /usr/local/bin/
install -m644 build/layer/libVkLayer_FROG_gamescope_wsi_aarch64.so /usr/local/lib/
sed 's|"library_path": *"[^"]*"|"library_path": "/usr/local/lib/libVkLayer_FROG_gamescope_wsi_aarch64.so"|' \
  build/layer/VkLayer_FROG_gamescope_wsi.aarch64.json > /etc/vulkan/implicit_layer.d/VkLayer_FROG_gamescope_wsi.aarch64.json
```

Build-fix notes baked into the patch: `src/hdmi.h` redefines `hdr_metadata_infoframe`/`hdr_output_metadata` that
libdrm's `drm_mode.h` now provides (renamed); `src/wlserver.cpp` uses libinput/udev outside its `#if HAVE_DRM`
includes. Keep `drm_backend` **enabled** — `-Ddrm_backend=disabled` leaves undefined references in 3.16.24. The DRM
backend is compiled but never used here. `gamescopereaper` must be installed too or the child exits immediately
("Failed to start process gamescopereaper").

## Running

```
export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp
gamescope -W 1440 -H 3008 -f --backend sdl -- vkcube                      # X11 client via Xwayland :1 + WSI layer
gamescope -W 1440 -H 3008 -f --backend sdl --expose-wayland -- vkcube --wsi wayland   # native Wayland client
```

`--backend sdl` is the nested path (SDL → X11 → Vulkan WSI on Termux:X11). As a unit: `Requires=x11.service`, the
same env file as the other display units, `ExecStart=/usr/local/bin/gamescope … -- <game>`. Stop `phosh.service`
first (or run on a second X display) — two compositors on `:0` fight for the screen.

## What works, what doesn't

| | |
|---|---|
| Vulkan clients (native Wayland or X11 through the WSI layer) | **GPU rendered + GPU composited**, vkcube at the Termux:X11 rate |
| gamescope features — scaling, FSR/NIS, frame limiter, `gamescopectl` | available (untested beyond start-up) |
| GL clients inside gamescope | **no**: they go through Xwayland, whose glamor falls back to software (no GBM on KGSL), so there is no GLX at all. Run GL apps straight on `:0` (freedreno/zink) as before; a Vulkan-glamor Xwayland is the thing to watch |
| `wl_drm` / linux-dmabuf v4 feedback | not advertised (no main device) — only matters for very old clients and for v4-feedback-only clients, which Mesa is not |
| Steam | not tried. DroidDeck shows Valve's ARM64 Linux Steam client + ARM64 Proton/FEX under gamescope on Adreno 7xx/8xx; the compositor half above is the same mechanism |

## Debugging notes

- The decisive tool was `wayland-info` against `gamescope-0` (`--expose-wayland`, `XDG_RUNTIME_DIR=/tmp`): compare the
  global list with what Mesa's WSI needs (`zwp_linux_dmabuf_v1` ≥ 3).
- gamescope's log lines that matter: `Creating Gamescope nested swapchain with format …` (the compositor's own
  presentation works), `Failed to get DRM FD from renderer` (expected on KGSL, harmless), `linux-dmabuf v3 created
  without a DRM device (KGSL)` (the patch is active).
- The env has no ptrace, so `strace` is unavailable; `VK_LOADER_DEBUG=error,warn,layer` on the client and
  `WAYLAND_DEBUG=1` substitute.
