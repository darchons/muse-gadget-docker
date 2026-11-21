# Muse Gadget (Linux SDK) in Docker — headless runtime, pairing via the host's BlueZ.
#
# Design (see README.md):
#   * Steady state ("gadget" service): no Bluetooth, no D-Bus, no host
#     network, no extra capabilities. It only needs the paired state in
#     /var/lib/musegadget and outbound HTTPS.
#   * Pairing ("pair" profile): shares the HOST's BlueZ over the host's
#     system D-Bus socket (/var/run/dbus). No bluetoothd runs in the image.
#
# The image is built by running the SDK's own install.sh, with three
# container adaptations:
#   * --yes --no-pair: no terminal in a build (its prompts read /dev/tty),
#     and pairing needs a live Bluetooth adapter over the system D-Bus,
#     which a build does not have. Pairing happens later, at runtime,
#     in the "pair" profile.
#   * NO --sdk-token: the token is never a build input. It reaches the
#     container at runtime via .env, and the entrypoint persists it to
#     the state volume exactly as install.sh --sdk-token would have.
#   * Secret scrub, in the SAME layer: install.sh's final step runs
#     `musegadget info`, which creates a device identity
#     (/var/lib/musegadget/identity.json — key material) as a side
#     effect. identity.json, pairing.json and sdk_token are deleted in
#     the same RUN that ran the installer, so they never land in any
#     image layer. The real identity is created fresh in the state
#     volume on first runtime use (`docker compose run --rm gadget info`).
#
# What install.sh writes that stays, inert: the systemd unit in
# /etc/systemd/system/ and /etc/bluetooth/main.conf. There is no systemd
# and no bluetoothd in the container — the entrypoint replaces the unit,
# and the BlueZ config that matters is the host's (host/setup-bluez.sh).

# ---------------------------------------------------------------- SDK source
FROM debian:12-slim AS sdk
ARG SDK_REPO=https://github.com/facebookincubator/muse-gadget-sdk.git
# Pin this to a commit SHA for reproducible builds, e.g.
#   docker compose build --build-arg SDK_REF=<sha>
ARG SDK_REF=main
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# --branch works for branches/tags; fall back to a full clone + checkout
# when SDK_REF is a commit SHA.
RUN git clone --depth 1 --branch "${SDK_REF}" "${SDK_REPO}" /sdk \
 || (rm -rf /sdk && git clone "${SDK_REPO}" /sdk && git -C /sdk checkout "${SDK_REF}")

# ------------------------------------------------------------------- runtime
FROM debian:12-slim

ARG GADGET_UID=1000
ARG GADGET_GID=1000

ENV PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    MUSEGADGET_RUN_AS=gadget \
    MUSEGADGET_STATE_DIR=/var/lib/musegadget \
    MUSEGADGET_SOCKET=/run/musegadget/musegadget.sock \
    DBUS_SYSTEM_BUS_ADDRESS=unix:path=/var/run/dbus/system_bus_socket

# tini is the only package installed outside install.sh (PID 1 / signal
# handling, replacing the parts of systemd the service relied on).
# Everything else — bluez, python3, python3-dbus, python3-gi,
# python3-cryptography, curl, ca-certificates, plus the pinned uv and
# the venv — is installed by install.sh itself, below.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/*

# The account Muse's commands run as. It must exist BEFORE install.sh:
# its choose_account step dies if --run-as names a nonexistent account
# (and refuses root). The service itself runs as root (state files, and
# BlueZ during pairing) and drops to this account for every command,
# exactly like the systemd unit's MUSEGADGET_RUN_AS.
RUN groupadd -g "${GADGET_GID}" gadget \
 && useradd -u "${GADGET_UID}" -g "${GADGET_GID}" -m -s /bin/bash gadget

# Run the SDK installer verbatim against the pinned local checkout
# (--from a directory installs that tree instead of git @main), then
# scrub every secret it created, in the same layer:
#   identity.json  created by the installer's closing `musegadget info`
#   pairing.json   not created under --no-pair; removed defensively
#   sdk_token      not created without --sdk-token; removed defensively
# The trailing tests make the build FAIL if any of them survived.
COPY --from=sdk /sdk/linux /tmp/muse-linux
RUN bash /tmp/muse-linux/install.sh \
      --from /tmp/muse-linux --run-as gadget --yes --no-pair \
 && rm -f /var/lib/musegadget/identity.json \
          /var/lib/musegadget/pairing.json \
          /var/lib/musegadget/sdk_token \
 && rm -rf /tmp/muse-linux /var/lib/apt/lists/* /root/.cache \
 && test ! -e /var/lib/musegadget/identity.json \
 && test ! -e /var/lib/musegadget/pairing.json \
 && test ! -e /var/lib/musegadget/sdk_token \
 && /opt/musegadget/venv/bin/musegadget --help >/dev/null

# Directory contract (systemd StateDirectory / RuntimeDirectory equivalents
# are re-asserted by entrypoint.sh on every start, since volumes and
# tmpfs start empty/foreign-owned):
#   /var/lib/musegadget        0700 root   (named volume: identity/pairing/token)
#   /run/musegadget            0755 root:gadget (local socket for send-user-msg)
#   /etc/musegadget/commands.d 0755 root   (synced from the bind mount by entrypoint)
RUN install -d -o root -g root   -m 0700 /var/lib/musegadget \
 && install -d -o root -g gadget -m 0755 /run/musegadget \
 && install -d -o root -g root   -m 0755 /etc/musegadget/commands.d

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

VOLUME ["/var/lib/musegadget"]

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["run"]
