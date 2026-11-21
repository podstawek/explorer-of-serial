# config — how this harness knows its environment

`go.sh` loads `config/explorer.<username>.json` (the machine/user identity is
used so several people can share the checkout; override with `EXPLORER_CONFIG`).
Copy `explorer.example.json` to `explorer.$(id -un).json` and point it at your
world.

This is deliberately **config, not secret**: API keys never appear in JSON —
opencode reads providers via your env / `$ENV_FILE` style wiring; llama.cpp
endpoints here need no auth on the LAN.

Keys:

- `solver` / `verifier` — the two model endpoints (solver = primary agent,
  verifier = critic). `modelID` and `ctx` go into the opencode agent headers.
- `target` — the machine under investigation: SSH alias, host, user.
- `jail_allow` — the network policy: allowed hosts; `go.sh`'s jail builder
  (`scripts/jail-props.py`) turns this into systemd `IPAddressAllow=`
  properties, and `scripts/netcheck.sh` verifies the exact same list from
  inside the jail before the run is allowed to start.
- `settings` — wall-clock timeout (minutes) and max agent steps.
