#!/usr/bin/env python3
"""Call one Home Assistant service — the exec target of ha.service.json.

Reads the command parameters as a JSON object on stdin (the SDK's drop-in
command contract), calls HA's REST API, and prints a JSON object back.
Errors exit non-zero; the last line on stderr becomes Muse's error reason.

Configuration (environment):
  HA_BASE_URL    default http://host.docker.internal:8123
  HA_TOKEN_FILE  file holding a HA long-lived access token
                 (default /run/secrets/ha_token)
  HA_TOKEN       the token itself (only if HA_TOKEN_FILE is unset/missing)

Standard library only. The token lives here, in the wrapper — Muse gets
the ha.service command, never the credential.
"""
import json
import os
import sys
import urllib.request
import urllib.error


def main() -> int:
    params = json.load(sys.stdin)
    domain = params["domain"]
    service = params["service"]

    body = {}
    if params.get("entity_id"):
        body["entity_id"] = params["entity_id"]
    if isinstance(params.get("service_data"), dict):
        body.update(params["service_data"])

    token = os.environ.get("HA_TOKEN", "")
    token_file = os.environ.get("HA_TOKEN_FILE", "/run/secrets/ha_token")
    if not token and os.path.exists(token_file):
        with open(token_file) as f:
            token = f.read().strip()
    if not token:
        print("no Home Assistant token configured", file=sys.stderr)
        return 1

    base = os.environ.get("HA_BASE_URL", "http://host.docker.internal:8123")
    req = urllib.request.Request(
        f"{base.rstrip('/')}/api/services/{domain}/{service}",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            changed = json.loads(resp.read() or b"[]")
    except urllib.error.HTTPError as exc:
        print(f"Home Assistant returned HTTP {exc.code}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"could not reach Home Assistant: {exc}", file=sys.stderr)
        return 1

    print(json.dumps({
        "ok": True,
        "changed_states": [s.get("entity_id") for s in changed
                           if isinstance(s, dict)],
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
