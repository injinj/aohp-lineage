# First boot → agent container → OpenClaw gateway → paired app

What the ROM gives you at first boot: `aohp-containerd` (root) and the **AOHP Driver**'s agent bridge on
`127.0.0.1:6666` are already running (the Driver is exempt from the first-boot *stopped* state), the OpenClaw app is
installed but has never been opened, and there is no container yet. Two ways to get from there to a running gateway —
the Driver's on-phone wizard (no computer) or headless from a host over adb (what the verification runs did). Both
end in the same state.

Terms: an **env** (= container, "sandbox") is a chroot of a rootfs template under `/data/aohp/envs/<name>`, sharing the
phone's network namespace; **`aohp`** is the CLI that talks to the bridge (ships inside every template and in
[injinj/aohp](https://github.com/injinj/aohp) `cli/aohp/dist/aohp.js`); the gateway listens on **`127.0.0.1:18789`**
and only one env can own that port at a time.

## A. On the phone (AOHP Driver wizard)

1. Open **AOHP Driver**. *Runtime* tab: bridge LISTENING 127.0.0.1:6666, a11y keepalive connected, 0 envs. No
   permission prompts.
2. *Harness* tab → **Set up OpenClaw**: name the env (`oc`), template `debian` → *Create* (~1 min: the tarball is
   inflated in RAM; 7–25 s on these phones).
3. Credentials step: **paste the Anthropic API key into the Keystore** (stored by the Driver in the Android Keystore,
   never on the container's disk), or **import a git config repo** (see B.3 — `gh auth login --web` device-code flow),
   or *Skip for now*.
4. *Start gateway* (Autostart is on by default) → "HTTP 200" after ~50 s (first start runs `npm install`) → *Open Control UI*
   (the Driver's *Web* tab is the full OpenClaw Control UI).
5. Pair the app — section C.

## B. Headless from a host (exactly what ran on both phones)

Prereqs on the host: `adb`, `node`, the `aohp` CLI (`node /path/to/aohp.js …`; below just `aohp`), and
`adb -s <serial> forward tcp:6666 tcp:6666` (the bridge is loopback-only on the phone). **Do not forward the gateway to
local port 18789 if the host runs its own OpenClaw gateway** — use `adb forward tcp:28789 tcp:18789`.

### B.1 Connect and create the env
```bash
adb -s <serial> forward tcp:6666 tcp:6666
aohp connect                                   # {"app":"org.aohp.driver","bridge":"aohp-driver","features":["secrets"]}
aohp sandbox list                               # []
aohp sandbox create -n oc -t debian             # "Container created: oc"   (7 s OnePlus, 25 s Pixel)
```
Templates available = the files in `/system/etc/aohp/rootfs-templates/` (`debian` in these builds).

### B.2 Run things inside the env
```bash
aohp sandbox exec oc uname -a
# containerd's execSync runs only the FIRST line of a script: send multi-line scripts as one base64 line
aohp sandbox exec oc bash -c "echo $(base64 -w0 myscript.sh) | base64 -d > /tmp/s.sh && bash /tmp/s.sh"
```
`sandbox exec` is root inside the env; long jobs: redirect to a log inside the env and poll it.

### B.3 Provision OpenClaw from git (aohp-agents bootstrap)
The container template is a thin Debian with Node 24, OpenClaw and the [aohp-agents](https://github.com/injinj/aohp-agents)
layer (`/opt/aohp-agents`, `aohp-bootstrap`, `aohp-secrets`, `aohp-update`). Your `~/.openclaw` (config, workspace,
skills — **no secrets**, `${ANTHROPIC_API_KEY}`-style references in `openclaw.json`) lives in a private config repo
(layout in the aohp-agents README; the one used here is `injinj/aohp-config-chris`), secrets age-encrypted in it as
`secrets/env.age`.

Inside the env (this is `oc-bootstrap.sh` from the runs, minus the secret delivery — see the note below):
```bash
curl -fsSL https://raw.githubusercontent.com/injinj/aohp-agents/main/bootstrap.sh | bash -s -- <github-user>/<config-repo> --secrets age --token-file /root/.secrets-tmp/token --passphrase-file /root/.secrets-tmp/pass
gh auth logout -h github.com
shred -u /root/.secrets-tmp/pass /root/.secrets-tmp/token
```
→ `rc=0` in 5–14 s: base packages, `gh auth` with the token, config repo cloned onto `/root/.openclaw`, `env.age`
decrypted to `/root/.openclaw/.env` (0600), OpenClaw present, launcher wrapper `/usr/local/bin/openclaw` installed.
Interactive alternative (no token file): `aohp-bootstrap <user>/<repo>` runs `gh auth login --web` (8-character device
code) and asks for the age passphrase.

*How the token and passphrase got into the env without ever being on a command line or in a log:* on the host,
`python3 -m http.server 8099 --bind 127.0.0.1` in a 0700 temp dir holding `gh-token` and `age-passphrase`,
`adb -s <serial> reverse tcp:8099 tcp:8099`, `curl http://127.0.0.1:8099/…` from inside the env into
`/root/.secrets-tmp/` (0700), then stop the server, `adb reverse --remove-all`, shred both copies.

### B.4 Move the key into the Driver's Keystore + phone-specific config
```bash
cd /root/.openclaw
aohp-secrets migrate keystore          # {"ok":true,"name":"ANTHROPIC_API_KEY"}; shreds .env
aohp secret list                       # ANTHROPIC_API_KEY  (lives in the AOHP Driver's Android Keystore from now on)
```
The launcher wrapper then fetches the key from the bridge at gateway start (`features: ["secrets"]`). Settings that the
verification runs added to `openclaw.json` for the phone (now folded into the config repo / aohp-agents, so a fresh
bootstrap gets them): `tools.codeMode.enabled=false`, `tools.toolSearch=false`, `tools.exec.timeoutSeconds=900`,
`agents.defaults.modelPolicy.allow=["anthropic/*"]`; the wrapper exports `SHELL=/bin/bash` (the service environment has
none, and `dash` breaks bashisms in the agent's `exec` tool); the workspace `AGENTS.md` tells the agent it has a real
bash shell and that the phone's own node is reachable through the `nodes` tool.

### B.5 Start the gateway as a containerd service
```bash
aohp sandbox svc-start -n oc -i openclaw-gateway -C "openclaw gateway"      # -> pid
adb -s <serial> forward tcp:28789 tcp:18789
curl -s http://127.0.0.1:28789/health                                      # {"ok":true,"status":"live"} after ~25-35 s
aohp sandbox exec oc openclaw agent --agent main --message "Reply with exactly: PONG"   # PONG
```
On the phone, `ss -ltnp` now shows `:18789` (openclaw-gateway) and `:6666` (org.aohp.driver). Known containerd quirk:
`svc-stop` only kills the `sh -c` wrapper on older builds; these ROMs carry the stop-pgid fix, but if a gateway ever
lingers: `aohp sandbox exec oc pkill -f '^openclaw-gateway'`.

## C. Pair the OpenClaw Android app (on the phone, no adb)

OpenClaw app → *Welcome* → **Set up manually** → host **`127.0.0.1`** (the app prefills the Wi-Fi IP — replace it),
port **18789**, no token, **Unencrypted** → *Test connection*. Over loopback with `auth.mode=none` the operator role
auto-pairs. Then up to two approvals are requested, each shown by the app with the exact command:

1. *"Pairing Gateway"* → `openclaw devices approve <id>` (node role; needed on the Pixel, not on the OnePlus where the
   device auto-paired with both roles) → *Retry connection* → "Gateway paired" → *Continue*.
2. *"Approve node access"* → `openclaw nodes approve <requestId>` → *I have approved*.

Run them in the **Driver's Terminal tab** (CLI cold start ~20 s) or from the host:
`aohp sandbox exec oc openclaw nodes approve <requestId>` (`openclaw devices list --json` /
`openclaw nodes pending --json` show what is waiting). Then the permissions screen (all optional — **do not pre-grant
with `adb install -g`/`pm grant`**, it breaks the app's onboarding; capabilities are chosen in the app's *Settings →
Phone Capabilities*) → connected (green dot, "AOHP on ARM64").

Verify from inside the env: `openclaw nodes status --json` lists the phone's node `connected:true`;
`openclaw nodes invoke --node "<name>" --command device.info` returns `{"deviceName":…,"appVersion":"2026.8.2"}`.
Every later widening of the node's command surface (toggling Camera etc.) produces another `nodes approve`;
`camera.*`/`screen.record` additionally need `gateway.nodes.commands.allow: [...]` in `openclaw.json` (hot-reloads).

## D. Autostart (survives reboots)

Harness → env card → **Autostart** switch (on by default when the wizard created the env; **off** for an env created
with `aohp sandbox create` — flip it in the UI). Since build-5 / dodge build-3 (Driver 0.4.0) Autostart means
**env-start**: containerd starts the env's *enabled units* (`/etc/aohp/system/aohp.target.wants`, see
[units.md](units.md)) in dependency order and supervises them (`Restart=on-failure` for the gateway, timers); envs
without unit files keep the 0.3.0 replay of recorded services. Done when, after `adb reboot` with no app opened, `ss -ltnp` shows
`:6666` (org.aohp.driver) and `:18789` (gateway), `curl …/health` is live (~60 s after boot), and the OpenClaw app
opens straight to *Online* without re-pairing. Verified on the Pixel 6 (AOHP GSI, 2026-10-02).

## E. Optional: WireGuard tunnel + sshd into the env (templates-20261005b, Driver ≥ 0.3.0)

Lets a host reach the container over a VPN (`ssh -p 2222 root@<wg0 addr>`; scp works, no bridge/base64 limits) — the
way the Pixel 6 env is reached from chex. Everything is installed in the template, nothing is active until you do this
inside the env (Terminal tab, or `aohp sandbox exec <env> …` with a base64 one-liner):

```bash
install -m 600 wg0.conf /etc/wireguard/wg0.conf        # [Interface] Address = 10.100.0.5/24 …, [Peer] … AllowedIPs = 10.100.0.0/24, 10.4.4.0/24
sed 's/@LISTEN_ADDRESS@/10.100.0.5/' /opt/aohp-agents/net/10-aohp.conf.template > /etc/ssh/sshd_config.d/10-aohp.conf
mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat id_ed25519.pub >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
wg0-sshd-startup.sh; cat /var/run/aohp-cron/net-watchdog.json     # expect exitCode 0, sshdPid set, handshakeAgeSec small
```

Then, **with build-5 / dodge build-3 and templates-20261005c**, inside the env:
`systemctl enable --now wg0 sshd net-watchdog.timer` (units: `wg0.service` oneshot, `sshd.service` with
`Restart=on-failure`, `net-watchdog.timer` = one `wg0-sshd-startup.sh` pass 2 min after env start then every 5 min;
`systemctl list-timers`, `journalctl -u sshd`). They come back on every boot through Autostart (env-start), before the
gateway (`After=wg0.service sshd.service`). See [units.md](units.md) for the migration of an env that still runs the
hand-started pair.
Pre-units images (build-4 / dodge-2) instead: from the host, once,
`aohp sandbox svc-start -n <env> -i net-watchdog -C "/usr/local/bin/wg0-sshd-startup.sh --loop 300"`; the Driver
records the service and restarts it (before the gateway) on every boot while the env's Autostart is on;
`aohp sandbox svc-list -n <env>` shows `net-watchdog` and `openclaw-gateway`. The watchdog re-cycles wg0 when the
`ip rule … lookup 51820` for an AllowedIPs subnet disappears (Android ignores the main table) and restarts sshd if it
died. With the build-4 sepolicy sshd needs no `LD_PRELOAD` shim.

## F. Updating the agent layer / OpenClaw inside the env

`aohp sandbox exec oc aohp-update` (= `git pull` of `/opt/aohp-agents` + re-run the installers listed in your
config repo's `aohp/agents`); `npm i -g openclaw@<version>` for OpenClaw itself. A new ROM build (new template) does not
touch existing envs in `/data`.
