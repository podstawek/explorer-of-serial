#!/usr/bin/env python3
"""Emit one CHECK|host|port|expected_http per line for netcheck.sh.

argv: config.json [expected.json]
kind: svc (model endpoint) | target (ssh) | internet | dns
"""
import json
import os
import sys

cfg_path, exp_path = sys.argv[1], len(sys.argv) > 2 and sys.argv[2] or None
cfg = json.load(open(cfg_path))
ja = cfg.get("jail_allow", {})
coarse = os.environ.get("COARSE") == "1"

import ipaddress

exp = {"internet": []}
if exp_path and os.path.exists(exp_path):
    exp.update(json.load(open(exp_path)))

def is_private(host: str) -> bool:
    try:
        return ipaddress.ip_address(host).is_private
    except ValueError:
        return False  # hostnames in the canary list are treated as public

for s in ([] if coarse else ja.get("services", [])):
    print(f"svc|{s['host']}|{s.get('probe_port', s['port_min'])}|{s.get('expected_http', '200')}")

if not coarse:
    tgt = os.environ.get("TARGET_HOST", "").strip()
    if tgt:
        for p in ja.get("target_ports", []):
            print(f"target|{tgt}|{p['port']}|")

for i in exp.get("internet", []):
    if coarse and is_private(i["host"]):
        continue  # LAN canaries are allowed-by-design in coarse mode
    print(f"internet|{i['host']}|{i['port']}|")
