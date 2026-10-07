#!/usr/bin/env python3
"""Faz 2 A-adimi: baglanti + auth + transit uc kaniti (stdlib-only, pip yok)."""
import base64
import json
import os
import ssl
import sys
import urllib.request

ADDR = os.environ["OPENBAO_ADDR"].rstrip("/")
MOUNT = os.environ["TRANSIT_MOUNT"]
KEY = os.environ["TRANSIT_KEY"]
PAYLOAD = b"transit-demo-A"

# Demo + self-signed icin verify kapali; gercek kullanimda CA bundle mount.
CTX = ssl._create_unverified_context()
print("TLS: verify kapali (demo + self-signed)", flush=True)


def post(path, body, token=None):
    req = urllib.request.Request(
        ADDR + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    if token:
        req.add_header("X-Vault-Token", token)
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        return json.load(r)


def read_file(p):
    with open(p) as f:
        return f.read().strip()


def main():
    role_id = read_file("/mnt/approle/role_id")
    secret_id = read_file("/mnt/approle/secret_id")
    login = post("/v1/auth/approle/login", {"role_id": role_id, "secret_id": secret_id})
    token = (login.get("auth") or {}).get("client_token")
    if not token:
        print("FAIL: approle login tokensiz dondu", flush=True)
        return 1
    print("login OK", flush=True)
    pt_b64 = base64.b64encode(PAYLOAD).decode()
    enc = post("/v1/" + MOUNT + "/encrypt/" + KEY, {"plaintext": pt_b64}, token)
    ct = (enc.get("data") or {}).get("ciphertext", "")
    if not ct.startswith("vault:v"):
        print("FAIL: ciphertext prefix", flush=True)
        return 1
    print("encrypt OK: " + ct, flush=True)
    dec = post("/v1/" + MOUNT + "/decrypt/" + KEY, {"ciphertext": ct}, token)
    pt2 = (dec.get("data") or {}).get("plaintext", "")
    if pt2 != pt_b64:
        print("FAIL: round-trip eslesmedi", flush=True)
        return 1
    print("decrypt OK: round-trip eslesti", flush=True)
    print("CONNECTIVITY PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
