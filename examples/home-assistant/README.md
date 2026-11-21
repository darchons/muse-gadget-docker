# Example: a Home Assistant command for Muse

`ha.service.json` is a drop-in command definition. Installed into
`commands.d/`, it gives Muse one narrow command — `ha.service` — instead
of general shell access to your HA instance:

```json
{"domain": "light", "service": "turn_on", "entity_id": "light.kitchen",
 "service_data": {"brightness_pct": 50}}
```

`ha-call.py` is the wrapper it executes. It reads those parameters as JSON
on stdin, calls `POST {HA_BASE_URL}/api/services/<domain>/<service>` with
a long-lived access token, and prints a JSON result. The token is read
from `HA_TOKEN_FILE` (default `/run/secrets/ha_token`) or `HA_TOKEN` —
it lives in the wrapper's environment, never in the command definition,
and Muse never sees it.

Enable it:

1. Copy `ha-call.py` into the gadget image as `/usr/local/bin/ha-call`
   (e.g. in a derived Dockerfile: `COPY ha-call.py /usr/local/bin/ha-call`).
2. Copy `ha.service.json` into the project's `commands.d/` and restart
   the `gadget` service.
3. Give the service `HA_BASE_URL` (default
   `http://host.docker.internal:8123` — HA on the Docker host) and a
   token file.

The reverse direction (HA events → Muse) doesn't use this at all: an HA
automation fires a webhook at a small bridge that shares the gadget's
`gadget-run` socket volume and runs `musegadget send-user-msg`. See the
SDK's `examples/pebble_ring_bridge.py` for the pattern.
