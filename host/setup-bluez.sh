#!/usr/bin/env bash
# Prepare the HOST's BlueZ for Muse Gadget pairing.
#
# Pairing from the container talks to the host's bluetoothd over the host
# system D-Bus, so the two tweaks the SDK's install.sh normally makes on a
# bare-metal install have to be made here, on the host, instead:
#
#   1. [GATT] ExchangeMTU = 256 in /etc/bluetooth/main.conf
#      The Android Muse app writes (MTU - 3)-byte packets and Android
#      rejects writes over 512 bytes. Without this, pairing gets as far as
#      the Wi-Fi step and then fails with "Couldn't connect".
#   2. bluetoothd --noplugin=battery (systemd drop-in)
#      The battery plugin asks a connecting phone to bond to read its
#      battery level; gadgets refuse bonding, and iOS pairing then drops.
#
# It also makes sure bluetoothd is enabled, running, and unblocked.
# Idempotent; safe to re-run. Run as root on the Docker host that has the
# Bluetooth adapter:
#
#   sudo bash host/setup-bluez.sh
set -euo pipefail

BLUEZ_CONF="/etc/bluetooth/main.conf"
BLUEZ_DROPIN="/etc/systemd/system/bluetooth.service.d/zz-musegadget.conf"

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root (sudo bash host/setup-bluez.sh)."
command -v systemctl >/dev/null || die "systemctl not found; this host does not run systemd."
command -v bluetoothctl >/dev/null || die "bluetoothctl not found; install BlueZ first (apt install bluez)."
if [ ! -d /sys/class/bluetooth ] || [ -z "$(ls /sys/class/bluetooth 2>/dev/null)" ]; then
    die "no Bluetooth adapter found on this host. Pairing needs a BLE adapter on the host that runs the pair profile."
fi

# --- ExchangeMTU = 256 -------------------------------------------------------
say "Setting BlueZ ExchangeMTU = 256 in $BLUEZ_CONF"
result="$(python3 -I - "$BLUEZ_CONF" <<'EOF'
import re, shutil, sys
path = sys.argv[1]
try:
    text = open(path).read()
except FileNotFoundError:
    text = ""
active = re.search(r"^\s*ExchangeMTU\s*=\s*(\d+)\s*$", text, re.M)
if active and int(active.group(1)) <= 256:
    print("unchanged"); sys.exit()
line = "ExchangeMTU = 256"
if active:
    text = text[:active.start()] + line + text[active.end():]
elif re.search(r"^\s*#\s*ExchangeMTU\s*=.*$", text, re.M):
    text = re.sub(r"^\s*#\s*ExchangeMTU\s*=.*$", line, text, count=1, flags=re.M)
elif re.search(r"^\[GATT\]\s*$", text, re.M):
    text = re.sub(r"^\[GATT\]\s*$", "[GATT]\n" + line, text, count=1, flags=re.M)
else:
    text = text.rstrip("\n") + ("\n\n" if text else "") + "[GATT]\n" + line + "\n"
try:
    shutil.copy2(path, path + ".pre-musegadget")
except FileNotFoundError:
    pass
open(path, "w").write(text)
print("changed")
EOF
)"
if [ "$result" = changed ]; then
    say "ExchangeMTU set (backup: $BLUEZ_CONF.pre-musegadget)"
else
    say "ExchangeMTU already OK"
fi

# --- --noplugin=battery drop-in ----------------------------------------------
say "Disabling BlueZ's battery plugin"
unit_text="$(systemctl cat bluetooth.service 2>/dev/null || true)"
result="$(python3 -I - "$BLUEZ_DROPIN" "$unit_text" <<'EOF'
import os, re, sys
path, unit_text = sys.argv[1], sys.argv[2]
lines = re.findall(r"^ExecStart=(.*)$", unit_text, re.M)
command = next((l.strip() for l in reversed(lines) if l.strip()), "")
if not command or any(c in command for c in "\"'\\$%;"):
    print("skipped"); sys.exit()
args = command.split()
for i, arg in enumerate(args):
    inline = arg.startswith("--noplugin=")
    if inline or (arg in ("-P", "--noplugin") and i + 1 < len(args)):
        names = arg.split("=", 1)[1] if inline else args[i + 1]
        if "battery" in names.split(","):
            print("unchanged"); sys.exit()
        names = names + ",battery" if names else "battery"
        if inline:
            args[i] = "--noplugin=" + names
        else:
            args[i + 1] = names
        break
else:
    args.append("--noplugin=battery")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    f.write("# Written for Muse Gadget pairing: never ask phones to bond.\n"
            "[Service]\nExecStart=\nExecStart=" + " ".join(args) + "\n")
print("changed")
EOF
)"
case "$result" in
    changed)   say "Battery plugin disabled ($BLUEZ_DROPIN)" ;;
    unchanged) say "Battery plugin already disabled" ;;
    skipped)   warn "could not parse bluetooth.service's ExecStart; left plugins as they are. If iPhone pairing drops, add --noplugin=battery to bluetoothd manually." ;;
esac

# --- enable + restart ---------------------------------------------------------
say "Enabling and restarting bluetooth.service"
if command -v rfkill >/dev/null; then rfkill unblock bluetooth || true; fi
systemctl daemon-reload
systemctl enable --now bluetooth.service
systemctl restart bluetooth.service

# --- verify -------------------------------------------------------------------
say "Verifying the adapter"
bluetoothctl show || die "bluetoothctl cannot talk to bluetoothd; check 'systemctl status bluetooth'."
bluetoothctl show | grep -q "Powered: yes" ||
    warn "adapter is not powered on; check 'bluetoothctl show' and rfkill."
bluetoothctl show | grep -q "peripheral" ||
    warn "adapter does not advertise a peripheral role; BLE pairing may not work with this adapter/driver."
say "Host BlueZ is ready. Pair with: docker compose --profile pair run --rm pair"
