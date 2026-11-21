#!/usr/bin/env python3
"""Assemble systemd-run -p properties for the explorer network jail.

Sources: config JSON .jail_allow + TARGET_HOST from .env (already exported by
go.sh). Prints one property per line, ends with IPAddressDeny=any.
Exit 2 on missing/empty TARGET_HOST — the jail must never silently omit the
target allowance (fail loud, fail closed).
"""
import json
import os
import subprocess
import sys


def port_filters_supported() -> bool:
    """Does THIS systemd understand IPAddressPortAllow= ? Removed in newer
    systemd (gone in v262: man page + binary have no trace). Detection beats
    version guessing. The probe runs unprivileged: if the property name is
    unknown, systemd-run errors out instantly client-side; if known, it
    advances to the D-Bus stage (slow access-denied/timeout) — either no
    fast 'Unknown assignment' = supported."""
    if os.environ.get("EXPLORER_FORCE_HOST_ONLY_JAIL", "").strip():
        return False
    try:
        p = subprocess.run(
            ["systemd-run", "--scope", "-p", "IPAddressPortAllow=192.0.2.1:53", "/bin/true"],
            capture_output=True, text=True, timeout=12)
        out = (p.stderr or "") + (p.stdout or "")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return "Unknown assignment" not in out

def main() -> int:
    cfg = json.load(open(sys.argv[1]))
    ja = cfg.get("jail_allow") or {}
    missing = [k for k in ja.get("require_env", []) if not os.environ.get(k, "").strip()]
    if missing:
        sys.stderr.write(f"jail: .env missing {', '.join(missing)} — refusing\n")
        return 2

    props = ["IPAddressAllow=127.0.0.0/8", "IPAddressAllow=::1/128"]
    if os.environ.get("EXPLORER_ALLOW_COARSE_LAN", "").strip():
        # Known leak, mitigation only (see docs/JAIL.md "Coarse mode"):
        # whole private space allowed, internet still denied. netcheck is told
        # (COARSE=1) so it stops asserting per-service and LAN-canary results.
        sys.stderr.write("jail: COARSE LAN mode — private space allowed (10/8, 172.16/12, 192.168/16)\n")
        print("\n".join(props + ["IPAddressAllow=10.0.0.0/8", "IPAddressAllow=172.16.0.0/12",
                                 "IPAddressAllow=192.168.0.0/16", "IPAddressDeny=any"]))
        return 0
    port_filters = port_filters_supported()
    if not port_filters:
        sys.stderr.write(
            "jail: systemd here has no IPAddressPortAllow (removed in newer systemd; "
            "see docs/JAIL.md) — degrading to HOST-level allowlists (any port on the "
            "listed hosts is reachable: only model servers + the target; internet still denied)\n")

    emitted_allow = set()
    def allow(host):
        if host not in emitted_allow:
            emitted_allow.add(host)
            props.append(f"IPAddressAllow={host}")

    for s in ja.get("services", []):
        allow(s["host"])
        if port_filters:
            lo, hi = s["port_min"], s["port_max"]
            rng = str(lo) if lo == hi else f"{lo}-{hi}"
            props.append(f"IPAddressPortAllow={s['host']}:{rng}")

    tgt = os.environ.get("TARGET_HOST", "").strip()
    for p in ja.get("target_ports", []):
        allow(tgt)
        if port_filters:
            props.append(f"IPAddressPortAllow={tgt}:{p['port']}")

    props.append("IPAddressDeny=any")
    print("\n".join(props))
    return 0

if __name__ == "__main__":
    sys.exit(main())
