# Muse Gadget (Linux SDK) in Docker

Container packaging of Meta's [Muse Gadget Linux SDK](https://github.com/facebookincubator/muse-gadget-sdk/tree/main/linux):
a service that pairs with the Muse app and then lets Muse run commands,
read/write files, and report health on "the device" — here, this container.

**Architecture: a headless runtime, plus pairing through the host's BlueZ.**

Bluetooth LE is only the initial pairing handshake. Once `pairing.json`
exists, the service talks to Muse over an outbound encrypted (Noise)
session on port 443, and never touches Bluetooth again. So:

| | Runtime (`gadget`) | Pairing (`pair`) |
|---|---|---|
| Lifetime | permanent | throwaway, once per (re)pairing |
| Bluetooth | none | host's BlueZ, shared over the host system D-Bus (`/var/run/dbus`) |
| Network | default bridge | `network_mode: host` |
| Privileges | none added | none added (root in container ↔ system bus) |
| State | `gadget-state` volume | same volume |

This mirrors the SDK's own headless deployment notes (pairing is bound to
`identity.json`, not to the machine that performed the BLE handshake),
which is also what makes this deployable on hosts with no Bluetooth at
all: pair on any BLE host, move the volume, run anywhere.

## Quick Start

No clone needed — these run straight off the published GHCR image.
Substitute your SDK token from gadgets.muse.ai for `mgst_…` in the
commands below.

### Pairing

One-time, on the host that has the Bluetooth adapter.

Apply the two bluetoothd settings pairing needs (`ExchangeMTU =
256`, battery plugin off) and verify the adapter — this fetches and
runs this repo's host setup script:

```sh
wget -qO- \
  https://raw.githubusercontent.com/darchons/muse-gadget-docker/main/host/setup-bluez.sh \
  | sudo bash
```

Create the device identity, and note the `MuseGadgetXXXXXX` name it
prints — that is the name to pick in the Muse app:

```sh
docker run --rm \
  -v muse-gadget-state:/var/lib/musegadget \
  ghcr.io/darchons/muse-gadget-docker:latest info
```

Open the 10-minute pairing window (host network + the host's system
D-Bus, so the container can use the host's BlueZ):

```sh
docker run --rm -it \
  --network host \
  -v /var/run/dbus:/var/run/dbus \
  -v muse-gadget-state:/var/lib/musegadget \
  -e MUSEGADGET_SDK_TOKEN=mgst_… \
  ghcr.io/darchons/muse-gadget-docker:latest pair
```

While the window is open, in the Muse app: **Settings → Devices →
Developer mode** on, then **Add Device**, pick `MuseGadgetXXXXXX`,
accept the community-device warning, and when asked for Wi-Fi pick
the network shown (the "device" is already online; no password is
needed). Success looks like `Paired.` in the container output, and
the `info` command above then reports `paired: yes`.

Pair on a network you trust: community pairing has no manufacturer
verification and cannot prevent an active man-in-the-middle attack.

### Run

Once paired, run the gadget headless — on the pairing host or any
other host that has the `muse-gadget-state` volume:

```sh
docker run -d \
  --name muse-gadget \
  --hostname docker-gadget \
  --restart unless-stopped \
  --add-host host.docker.internal:host-gateway \
  -v muse-gadget-state:/var/lib/musegadget \
  -e MUSEGADGET_SDK_TOKEN=mgst_… \
  ghcr.io/darchons/muse-gadget-docker:latest
```

The `--hostname docker-gadget` argument names the gadget: the name
it shows in Muse is its container hostname, so it appears as
`docker-gadget`. The node id (`homelink-XXXXXX`) is unaffected —
change the hostname to rename the gadget, and recreate the
container to apply it.

All three commands share the `muse-gadget-state` Docker volume,
which holds the identity, pairing, and token. Never run pairing and
the gadget at the same time — one identity may only hold one live
session. The compose-based flow in steps 1–4 below does the same
thing from a clone of this repo, with the token kept in `.env`
instead of on the command line.

## What Muse gets

Commands run inside the container, as the unprivileged `gadget` account
(the service runs as root and drops privileges per command, exactly like
the bare-metal systemd unit). Mounting host paths, the Docker socket, or
`--privileged` into the runtime hands that access to Muse — don't,
unless that's the point.

## Prerequisites

- A Docker host (the pairing step additionally needs a BLE adapter *on
  that host* and systemd + BlueZ on it).
- An SDK token from gadgets.muse.ai (Account → SDK tokens).
- The Muse app on your phone.

## 1. Prepare the host's Bluetooth (once, on the pairing host)

```sh
sudo bash host/setup-bluez.sh
```

This applies the two changes `install.sh` would have made on bare metal —
`ExchangeMTU = 256` and `bluetoothd --noplugin=battery` — to the **host's**
bluetoothd, and verifies the adapter is powered and can act as a peripheral.
It does not stop or replace the host's bluetoothd; other Bluetooth users
on the host keep working, modulo the battery-plugin change.

> If your Docker daemon uses user-namespace remapping, the pairing
> container's root is not host root and the system bus will refuse it.
> Disable remapping for this daemon, or pair on a host without it.

## 2. Configure and build

```sh
cp .env.example .env   # fill in MUSEGADGET_SDK_TOKEN
docker compose build   # optionally SDK_REF=<commit-sha> in .env to pin the SDK
```

The build runs the SDK's own `install.sh` against the pinned checkout,
with `--yes --no-pair` and **no `--sdk-token`** — the token is a runtime
input (`.env`), never a build input. The installer's closing
`musegadget info` step creates a device identity as a side effect; the
Dockerfile deletes `identity.json`, `pairing.json` and `sdk_token` in
the same layer that ran the installer, and fails the build if any of
them survives. So the image contains no token, no identity, and no
pairing — safe to push to a registry. The real identity is created in
the state volume in step 3.

### …or use the prebuilt image (GHCR)

GitHub Actions builds this image on every push to `main` and publishes
it to the GitHub Container Registry as
`ghcr.io/darchons/muse-gadget-docker` — multi-arch (`linux/amd64`,
`linux/arm64`), tagged `latest`, `main`, the short commit SHA, and the
version on `v*` tags. Because the image contains no token, identity, or
pairing (above), it is safe to pull from anywhere.

To use it instead of building:

```sh
# in .env — the token is still needed; it is a runtime input
GADGET_IMAGE=ghcr.io/darchons/muse-gadget-docker:latest

docker compose pull        # fetches the prebuilt image; skip `docker compose build`
```

Then continue with step 1 (host Bluetooth prep still applies — it is a
host property, not an image property) and steps 3–4 as written; both
the runtime and the pairing service use the pulled image.

If the package is private, authenticate first with a GitHub token that
has `read:packages`:

```sh
echo "$GH_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
```

(Making the package public under the repo's Packages settings removes
that step — reasonable here, since the image carries no secrets.)

## 3. Create the identity, then pair

```sh
docker compose run --rm gadget info
#   node id:   homelink-XXXXXX (when paired)
#   BLE name:  MuseGadgetXXXXXX      <-- the name to pick in the app

docker compose --profile pair run --rm pair
```

While the 10-minute window is open, in the Muse app:
**Settings → Devices → Developer mode** on, then **Add Device**, pick
`MuseGadgetXXXXXX`, accept the community-device warning, and when asked
for Wi-Fi pick the network shown (the "device" is already online; no
password is needed). Success looks like `Paired.` in the container output
and `paired: yes` from `docker compose run --rm gadget info`.

Pair on a network you trust: community pairing has no manufacturer
verification and cannot prevent an active man-in-the-middle attack.

## 4. Run

```sh
docker compose up -d gadget
docker compose logs -f gadget
#   healthy:  commands run as gadget
#             Noise session established
#             sent link.register as homelink-XXXXXX
#             registered with the Muse
```

Ask Muse to run `hostname` on the device — it should answer with the
container's hostname. Then test the local socket path:

```sh
docker compose exec gadget musegadget send-user-msg "Gadget container is up."
```

## State, backup, re-pairing

Everything that matters is in the `gadget-state` volume
(`/var/lib/musegadget`, mode 0700):

- `identity.json` — the device identity (survives unpairing)
- `pairing.json` — device tokens from pairing
- `sdk_token` — your `mgst_…` token (written from `.env` at every start)

Back it up and the gadget can be restored or moved to another host
without re-pairing:

```sh
docker run --rm -v muse-gadget_gadget-state:/s -v "$PWD":/b alpine \
  tar -C /s -czf /b/gadget-state.tgz .
```

Re-pairing (revoked/rotated token, removed device) = repeat step 3 with
`command: ["pair", "--force"]` on the pair service, or run
`docker compose --profile pair run --rm pair` after `unpair`. Changing
the SDK token only takes effect after re-pairing — Muse records a
device's token when it pairs.

Never run `gadget` and `pair` (or two gadgets with the same volume) at
the same time: two live holders of one identity create competing link
sessions.

## Custom commands

Drop `*.json` definitions in `./commands.d/` (see the SDK README for the
schema) and restart `gadget`. The bind mount is only a source: because the
service runs as root, the SDK refuses definitions that aren't root-owned
and root-only-writable, so the entrypoint syncs the mount into a
root-owned `/etc/musegadget/commands.d` at start.

`examples/home-assistant/` is a worked example: `ha.service.json` gives
Muse a single narrow `ha.service` command whose wrapper (`ha-call.py`)
calls Home Assistant's REST API with a long-lived token Muse never
sees. To enable it, copy `ha-call.py` to `/usr/local/bin/ha-call` in a
derived image, copy the JSON into `commands.d/`, and give the gadget
service `HA_BASE_URL` / `HA_TOKEN_FILE` plus a route to HA
(`host.docker.internal` works for HA on the Docker host).

The other direction — HA → Muse — needs no command at all: any program
that can reach the gadget's local socket can run
`musegadget send-user-msg` (optionally `--image`, `--wait`,
`--session-id`). Share the `gadget-run` volume with a bridge sidecar to
give HA automations a webhook target, following the SDK's
`examples/pebble_ring_bridge.py`.

## `doctor` in a container — read it correctly

`docker compose run --rm gadget doctor` works, but two results are
expected artifacts of containerisation, not faults:

- **Service: FAIL** — doctor looks for a systemd unit; there is none.
  (Consequently doctor exits 1 in the container. Don't use it as a
  healthcheck; use the log lines in step 4.)
- **Bluetooth: WARN** in the runtime — correct; Bluetooth is only needed
  for pairing. In the `pair` profile it should be OK after step 1.

Exit **78** from the service means the system trust store still trusts a
compromised root CA. The systemd unit refuses to restart on 78; the
entrypoint mirrors that by parking the container instead of
crash-looping. Fix = rebuild the image (fresh `ca-certificates`) and
recreate the container.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Pairing fails at the Wi-Fi step, "Couldn't connect" | Host `/etc/bluetooth/main.conf` missing `ExchangeMTU = 256` — re-run step 1 and restart bluetoothd |
| iPhone pairing drops early | Host bluetoothd still running the battery plugin — step 1 |
| `no Bluetooth adapter found` in pair logs | No adapter on *this* host, bluetoothd down, or `/var/run/dbus` mount missing |
| D-Bus permission errors in pair logs | userns-remapped Docker daemon (see step 1 note) |
| Phone shows GATT status 133 | Stale Bluetooth state on the phone — toggle phone Bluetooth and retry |
| `paired: yes, with SDK token …` in `info` | Token changed after pairing — re-pair with `--force` |
| Runtime logs loop on `not paired` | The volume was recreated or pairing was done against a different volume — check `docker volume ls` |
| `device.health` shows no temperature / container uptime | Expected — it reports the container's view of the system |

## Updating

Local builds: rebuild with a new `SDK_REF`, recreate the container.
GHCR users: `docker compose pull`, then recreate. The state volume
(and pairing) survives either way. Check the service log for recent
`invoke` lines first — a restart interrupts any command Muse is
currently running.

## Swarm / Komodo note

Run this as a single-replica service with the state volume on one node.
The runtime needs nothing special from the swarm; do the pairing step
outside the swarm (step 3) on a BLE-capable host sharing the same volume,
then start the service.
