#!/usr/bin/env bash
# Container entrypoint for the Muse Gadget Linux SDK.
#
# Replaces the three things systemd did for the bare-metal install:
#   StateDirectory=musegadget   -> /var/lib/musegadget, mode 0700
#   RuntimeDirectory=musegadget -> /run/musegadget, mode 0755 (the socket dir)
#   RestartPreventExitStatus=78 -> exit 78 (bad system trust store) parks the
#                                  container instead of crash-looping under a
#                                  Compose restart policy.
#
# Usage (container command):
#   run            (default) stay connected to Muse and serve commands
#   pair [--force] open the 10-minute Bluetooth pairing window (pair profile)
#   doctor|info|unpair|send-user-msg|chat|voice-call   passed to musegadget
#   shell          a root bash shell
#   anything else  executed as-is
set -euo pipefail

MUSEGADGET_BIN="${MUSEGADGET_BIN:-/opt/musegadget/venv/bin/musegadget}"
RUN_AS="${MUSEGADGET_RUN_AS:-gadget}"
STATE_DIR="${MUSEGADGET_STATE_DIR:-/var/lib/musegadget}"
SOCKET_PATH="${MUSEGADGET_SOCKET:-/run/musegadget/musegadget.sock}"
COMMANDS_SRC="${MUSEGADGET_COMMANDS_SRC:-/mnt/commands.d}"
COMMANDS_DIR="${MUSEGADGET_COMMANDS_DIR:-/etc/musegadget/commands.d}"

export MUSEGADGET_RUN_AS="$RUN_AS"
export MUSEGADGET_STATE_DIR="$STATE_DIR"
export MUSEGADGET_SOCKET="$SOCKET_PATH"
export MUSEGADGET_COMMANDS_DIR="$COMMANDS_DIR"

log() { printf 'entrypoint: %s\n' "$*"; }

# --- directories -------------------------------------------------------------
install -d -o root -g root -m 0700 "$STATE_DIR"
# Socket dir group is the run-as account's group: the service restricts the
# local socket to root and that group, which is what lets programs running
# as $RUN_AS use `musegadget send-user-msg` with no credentials of their own.
install -d -o root -g "$RUN_AS" -m 0755 "$(dirname "$SOCKET_PATH")"

# --- SDK token ---------------------------------------------------------------
# Same as `install.sh --sdk-token`: persisted root-only in the state dir.
# A token supplied by environment wins and is (re)written to the file.
if [ -n "${MUSEGADGET_SDK_TOKEN:-}" ]; then
    printf '%s\n' "$MUSEGADGET_SDK_TOKEN" |
        install -o root -g root -m 0600 /dev/stdin "$STATE_DIR/sdk_token"
    log "SDK token saved to $STATE_DIR/sdk_token (from environment)"
fi

# --- custom commands ---------------------------------------------------------
# commands.py refuses drop-in definitions that are not root-owned and
# root-only-writable when the service runs as root — a host bind mount is
# neither. So the bind mount is a *source*: sync it into the real,
# root-owned commands dir on every start.
if [ -d "$COMMANDS_SRC" ] && [ -n "$(ls -A "$COMMANDS_SRC" 2>/dev/null)" ]; then
    install -d -o root -g root -m 0755 "$COMMANDS_DIR"
    find "$COMMANDS_DIR" -mindepth 1 -delete
    cp -a "$COMMANDS_SRC/." "$COMMANDS_DIR/"
    chown -R root:root "$COMMANDS_DIR"
    find "$COMMANDS_DIR" -type d -exec chmod 0755 {} +
    find "$COMMANDS_DIR" -type f -exec chmod 0644 {} +
    log "custom commands synced: $(find "$COMMANDS_DIR" -type f -printf '%f ')"
fi

# --- dispatch ----------------------------------------------------------------
cmd="${1:-run}"
case "$cmd" in
    run)
        shift
        # Not exec'd: we need the exit code to honour the exit-78 rule.
        # tini forwards SIGTERM/SIGINT; the trap relays it to the service,
        # whose own handlers restore the Bluetooth adapter after pairing
        # sessions and close the Muse session cleanly.
        "$MUSEGADGET_BIN" run "$@" &
        child=$!
        trap 'kill -TERM "$child" 2>/dev/null || true' TERM INT
        set +e
        wait "$child"
        rc=$?
        set -e
        if [ "$rc" -eq 78 ]; then
            log "musegadget exited 78: the system trust store still trusts a"
            log "compromised root CA. Parking (systemd would not restart it"
            log "either). Update ca-certificates in the image, rebuild, and"
            log "recreate this container."
            trap - TERM INT
            exec sleep infinity
        fi
        exit "$rc"
        ;;
    pair|doctor|info|unpair|send-user-msg|chat|voice-call)
        shift
        exec "$MUSEGADGET_BIN" "$cmd" "$@"
        ;;
    shell)
        exec /bin/bash
        ;;
    *)
        exec "$@"
        ;;
esac
