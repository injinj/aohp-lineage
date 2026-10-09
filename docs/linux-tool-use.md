# Linux tool use on a phone: the four ways to run an agent runtime on Android

The architecture diagram in the [README](../README.md#what-runs-inside-what) raises an obvious question:
*couldn't this just be an app?* It could — three other projects answer the question that way — but each answer
trades something different. This page lays out the options as they stand in late 2026, and why AOHP-on-Lineage
is a ROM.

## What "Linux tool use" means and why it is the dividing line

An OpenClaw agent is only interesting because of its tools: `exec`, file read/write, git, package managers,
browsers, the whole Unix toolbox. That is **Linux tool use** — the agent runs real processes against a real
filesystem. It is a different capability from what the platform vendors are shipping:

| Vendor | Agent | What it operates on |
|---|---|---|
| Google | Gemini on Android 16/17 | **AppFunctions** (Android 16+: apps expose typed functions to agent apps, MCP-style) and the accessibility/UI layer; Android 17 positions Gemini as an OS sub-layer |
| OpenAI | ChatGPT app, Operator/agent mode | A cloud-hosted browser and the vendor's own tools; the phone app is a thin client |
| Honor | YOYO / "YOYO Claw" (MagicOS 10–11) | Cross-device orchestration of first-party and partner services (shopping, ride-hailing, pickup codes) |
| Xiaomi | Super XiaoAI 2.0 (HyperOS 4) | 130+ integrated services as of mid-2026 — food delivery, ride-hailing, music, exercise |

None of those have a shell. They don't need one: their "tools" are app intents, service APIs and screen automation,
all callable from an ordinary app process. **The platform agents and OpenClaw are not competing for the same
primitive.** They operate *apps*; OpenClaw operates *Linux*. That is exactly the capability Android's security model
is built to deny to an app — and it is the reason the question "which way do we run it" has only a few answers.

## The constraint: who is allowed to exec a binary

Two Android rules shape every option below:

1. **W^X for app data (Android 10+, targetSdk ≥ 29).** An app may not `execve()` a file it wrote to its own data
   directory. The only executable location an app controls is the native-library directory inside its APK
   (`jniLibs/<abi>/*.so`), populated at install time.
2. **Play Store targetSdk policy.** New and updated apps must target a recent SDK, so an app cannot opt out of rule 1
   by targeting API 28 and still ship through Play. (Termux does exactly that, which is why it lives on F-Droid and
   GitHub rather than Play.)

Add to that: no root, SELinux `untrusted_app` domain, Doze and the low-memory killer treating a long-lived gateway
as just another background app, and no cgroups or unit supervision of your own.

## The four ways

### 1. su — a rooted stock phone

Magisk or similar; the gateway runs in a real chroot or container as root, with real cgroups.

- **Gets:** the actual Node runtime, unchanged; good process isolation; cheap to try.
- **Pays:** the device's attestation (Play Integrity) and much of its sepolicy story; every OTA re-fights root;
  no supervision beyond whatever init-script you wrote. A hobbyist path, not something to hand to someone else.

### 2. Termux / PRoot — an app, no root

The runtime (real Node, from a Debian/Alpine rootfs) runs under **PRoot**, a ptrace-based userspace chroot. This is
what Termux does, and what the store-listed "run OpenClaw on your phone" apps do (e.g. AnyClaw, andClaw).

- **Gets:** the actual Node runtime; works on any Android 8+ phone; **the only option that can ship in the
  Play Store.** The way they get past rule 1: ship `libproot.so` and `libproot-loader.so` in `jniLibs`, and let
  PRoot's loader map the guest binaries into memory instead of `execve()`-ing them, so the kernel only ever sees
  the loader run.
- **Pays:** every syscall goes through ptrace (fine for JS-heavy Node, painful for anything fork/exec-heavy such
  as builds and package installs); the gateway is an app-uid process that Doze and the LMK will kill (a foreground
  service with a persistent notification mitigates, not prevents); no real isolation between the agent's shell
  and the app itself; and it rests on a loader trick that one security hardening release could close.

### 3. ROM — AOHP on LineageOS (this repository)

The container runtime is a root daemon in the system image (`aohp-containerd`), with its own SELinux domains
(`aohp_*`), cgroups, and a systemd-subset unit manager. The gateway is a *system service* in a Debian env, not an
app. The Driver app and the OpenClaw app are ordinary apps on top.

- **Gets:** the real runtime with real isolation and supervision; a native chroot (no ptrace); the gateway survives
  Doze, LMK and app lifecycle because it isn't in one; sepolicy that is enforcing rather than bypassed; upstream
  OpenClaw merges land unchanged.
- **Pays:** a flash. One ROM build per device, per AOSP tag, and someone to keep it current. Not store-shippable by
  definition; the audience is people who already flash Lineage.

### 4. Rewrite — reimplement the runtime for the platform

FlutterClaw (March–June 2026) rewrote the gateway, agent loop and tools in Dart, keeping only the OpenClaw
WebSocket protocol and config format; PRoot was used just for the shell tool.

- **Gets:** store-shippable, iOS too, native device tools (location, health, camera, accessibility automation) as
  first-class agent tools.
- **Pays:** it isn't OpenClaw anymore. Every upstream feature — compaction, memory, skills, plugins, channel
  adapters — has to be re-done by hand and drifts the moment upstream moves. FlutterClaw stopped tracking after
  roughly three months. A rewrite is cheap in 2026; *tracking* is the expensive part, and it's the part the ROM route
  gets for free.

## Summary

| | Real runtime | Isolation / supervision | Survives Doze/LMK | Store-shippable | Cost |
|---|---|---|---|---|---|
| su | yes | real (DIY) | yes | no | root your phone |
| Termux/PRoot | yes | ptrace, app-uid | partly | **yes** | perf + fragility |
| ROM (AOHP) | yes | **real, enforcing** | **yes** | no | a flash per device |
| Rewrite | no | app-uid | partly | yes | perpetual re-implementation |

If the goal is "OpenClaw on a phone I can hand to someone", option 2 is the honest answer and the apps doing it
deserve the attention. If the goal is "the real gateway as a trustworthy always-on system service on *my* phone",
there is only option 3 — and the diagram in the README is what it looks like.

## Where this meets the platform agents

The two worlds will touch at **AppFunctions**: an agent-app on Android 16+ can call functions other apps expose. The
AOHP Driver app is already the bridge between the Linux side and the Android side (`ws://127.0.0.1:6666`, Binder
to the framework); exposing device capabilities to the gateway as tools — and, conversely, letting Gemini-style
agents invoke the Linux agent as *a* function — is the natural next step, and the one none of the four options
above gets for free.
