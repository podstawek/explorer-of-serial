# Jail design & (current) limitations

## What is proven working on this host (harness-box, systemd v262)
- `systemd-run --scope -p IPAddressDeny=any` + the other `IPAddressAllow=`
  properties: verified in a live scope — target ssh :22 reachable, internet and
  LAN canaries blocked (`sh` probes, 2026-11-14). System-mode scope + `--uid`
  (user-mode instances silently ignore the IP filters — see go.sh warning).
- Unit properties must be passed as **`-p Name=value`**; bare `Name=value`
  positionals are NOT parsed as properties — the first one is treated as the
  command to exec (cryptic `Failed to find executable IPAddressAllow=...`).
- **`IPAddressPortAllow=`/`IPAddressPortDeny=` do NOT exist in v262** — no man
  entry, no trace in the binary; `IPAddressAllow=IP:port` suffixes are likewise
  rejected ("Failed to parse IP address prefix"). `scripts/jail-props.py` probes
  capability at runtime and DEGRADES TO HOST-LEVEL allowlists when unavailable:
  any port on the listed hosts (model servers + target) is reachable, internet
  still denied. Force with `EXPLORER_FORCE_HOST_ONLY_JAIL=1`. To restore port
  granularity on such a host: nftables rules matching the scope's cgroup
  (`meta cgroupv2`), or an older systemd.
- `IPAddressDeny=any` does NOT restrict DNS lookups by itself (DNS is UDP
  sockets); it drops/connect-fails packets to denied addresses — fine for us:
  resolv.conf points LAN-ward and every public resolver is denied, so lookups
  never resolve (netcheck asserts this).
- eBPF filter semantics: strong enough to stop `ssh`, browsers, nmap, python
  sockets entirely (connect EACCES), but NOT raw sockets (CAP_NET_RAW in
  non-root user namespace).

## Two-layer approach in this harness
1. **OpenCode permission layer** (always on): `"*": "deny"` network-ish tools,
   ssh-only bash allow-list. The model cannot fetch URLs — no tool for it — and
   its shell is `bash ssh ...` only.
2. **Jail layer** (opt-in, precise or coarse):
   - precise: allow = config `jail_allow` + `EXPLORER_ALLOW_COARSE_LAN=0`.
   - coarse: model hosts + RFC1918 /8s (for when you want ssh-anywhere).
Both run `scripts/netcheck.sh` INSIDE before the agent starts: it aborts (rc=3)
if any internet endpoint answers — i.e. if the jail failed, the run refuses to
proceed.

## Residual risks (precise mode ON harness-box today)
- Host-level degradation (no port filter on v262): if a listed host (thorgal,
  spark, the target) ran another service we'd rather not expose (DBs, admin
  ports), the jailed agent can reach it. Accepted trade-off for this fleet.
- Raw-socket egress (needs root or CAP_NET_RAW — not default for lab user).
- Routing side channels (no rp_filter tampering available unprivileged).
- IPv6 (the jail allows only listed v4; IPv6 default is deny-all when enabled —
  netcheck also probes an IPv6 literal, currently skipped on this box).
- The jail is NOT designed against an adversary who can modify jail-props.py
  output (system prompt is not a security boundary for the model, but the model
  cannot reach the props path because the sandboxed shell only runs ssh).

## Manual test (recommended once as root)
`bash scripts/install-jail.sh --test` gives the full procedure.
