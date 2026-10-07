#!/usr/bin/env python3
"""Faz 2 B-adimi: A-fazi (server-side baglanti kaniti) + B-fazi (gercek envelope).

B-fazi akisi (DEK/KEK deseni):
  1. Transit'ten taze DEK istenir (datakey/plaintext, bits 256) ->
     acik DEK + kilitli DEK (wrapped, KEK ile sarili) doner.
  2. Demo yuku, acik DEK ile YERELDE AES-256-GCM ile sifrelenir
     (taze 12-byte nonce, AAD olarak key adi baglamli).
  3. Acik DEK bellekten birakilir; saklanan paket =
     [sifreli veri + kilitli DEK + nonce]. Acik DEK saklanmaz.
  4. Cozum icin kilitli DEK Transit'e coz durulur, donen acik DEK ile
     veri yerelde cozulur ve orijinal yukle karsilastirilir.

Guvenlik notlari:
  - Plaintext DEK ve demo yuku log'a ASLA yazilmaz.
  - TLS dogrulamasi kapali: yalniz demo + self-signed icin; prod'da
    CA bundle mount + verify=<ca_path> kullanilmalidir.
  - 'del' bellek hijyenidir, zeroization garantisi degildir.
"""

import base64
import hashlib
import hmac
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# --- Yapilandirma: yalniz ortam degiskenleri, hardcoded default YOK ---
ADDR = os.environ["OPENBAO_ADDR"].rstrip("/")
MOUNT = os.environ["TRANSIT_MOUNT"]
KEY = os.environ["TRANSIT_KEY"]
ROLE_ID_PATH = os.environ.get("APPROLE_ROLE_ID_PATH", "/mnt/approle/role_id")
SECRET_ID_PATH = os.environ.get("APPROLE_SECRET_ID_PATH", "/mnt/approle/secret_id")
CA_BUNDLE_PATH = os.environ.get("CA_BUNDLE_PATH", "")
PAYLOAD = b"transit-demo-B-envelope"

# Kodu 1: login, 2: A-fazi, 3: B-fazi sifrele, 4: B-fazi coz,
# 99: beklenmeyen hata (asagidaki hicbir faz koduyla cakismaz).
RC_LOGIN = 1
RC_PHASE_A = 2
RC_PHASE_B_ENC = 3
RC_PHASE_B_DEC = 4
RC_UNEXPECTED = 99


def build_ssl_context() -> ssl.SSLContext:
    """Exporter ile ayni desen: CA bundle varsa dogrula, yoksa acikca
    dogrulamasiz devam et (demo + self-signed). Private
    ssl._create_unverified_context() kullanilmaz."""
    if CA_BUNDLE_PATH and os.path.isfile(CA_BUNDLE_PATH):
        return ssl.create_default_context(cafile=CA_BUNDLE_PATH)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    print("TLS: verify kapali (demo + self-signed;"
          " prod icin CA_BUNDLE_PATH set edin)", flush=True)
    return ctx


CTX = build_ssl_context()


def post(path: str, body: dict, token: str | None = None, fail_rc: int = 10) -> dict:
    """OpenBao API POST; hata govdesi loglanmaz (sızıntı yüzeyi kapalı).
    HTTP hatasinda cagri noktasinin faz kodu (fail_rc) ile cikilir."""
    req = urllib.request.Request(
        ADDR + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    if token:
        req.add_header("X-Vault-Token", token)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        print(f"FAIL: {path} HTTP {e.code}", flush=True)
        raise SystemExit(fail_rc)


def read_file(p: str) -> str:
    with open(p) as f:
        return f.read().strip()


def phase_a_login() -> str:
    role_id = read_file(ROLE_ID_PATH)
    secret_id = read_file(SECRET_ID_PATH)
    login = post("/v1/auth/approle/login", {"role_id": role_id, "secret_id": secret_id},
                 fail_rc=RC_LOGIN)
    token = (login.get("auth") or {}).get("client_token")
    if not token:
        print("FAIL: approle login tokensiz dondu", flush=True)
        raise SystemExit(RC_LOGIN)
    print("A: login OK", flush=True)
    return token


def phase_a_roundtrip(token: str) -> None:
    pt_b64 = base64.b64encode(PAYLOAD).decode()
    enc = post(f"/v1/{MOUNT}/encrypt/{KEY}", {"plaintext": pt_b64}, token,
               fail_rc=RC_PHASE_A)
    ct = (enc.get("data") or {}).get("ciphertext", "")
    if not ct.startswith("vault:v"):
        print("FAIL: A ciphertext prefix", flush=True)
        raise SystemExit(RC_PHASE_A)
    print("A: encrypt OK (key " + ct.split(":")[1] + ")", flush=True)
    dec = post(f"/v1/{MOUNT}/decrypt/{KEY}", {"ciphertext": ct}, token,
               fail_rc=RC_PHASE_A)
    if (dec.get("data") or {}).get("plaintext", "") != pt_b64:
        print("FAIL: A round-trip eslesmedi", flush=True)
        raise SystemExit(RC_PHASE_A)
    print("A: decrypt OK round-trip eslesti", flush=True)


def phase_b_envelope(token: str) -> None:
    # 1. Taze DEK iste (acik + kilitli birlikte gelir).
    dk = post(f"/v1/{MOUNT}/datakey/plaintext/{KEY}", {"bits": 256}, token,
              fail_rc=RC_PHASE_B_ENC)
    data = dk.get("data") or {}
    wrapped, pt_b64 = data.get("ciphertext", ""), data.get("plaintext", "")
    if not wrapped.startswith("vault:v") or not pt_b64:
        print("FAIL: B datakey uretilemedi", flush=True)
        raise SystemExit(RC_PHASE_B_ENC)
    dek = base64.b64decode(pt_b64)

    # 2. Veriyi YERELDE sifrele (AAD: key adi baglami).
    nonce = os.urandom(12)
    aad = KEY.encode()
    try:
        ct = AESGCM(dek).encrypt(nonce, PAYLOAD, aad)
    finally:
        # Hijyen, zeroization degil; encrypt patlasa da calisir.
        del dek
    # 3. Log'a hassas veri yazmadan ilerle (acik DEK yukarida birakildi).
    print("B: encrypt OK wrapped=" + wrapped, flush=True)
    print("B: nonce=" + nonce.hex() + " ct_sha256="
          + hashlib.sha256(ct).hexdigest(), flush=True)

    # 4. Kilitli DEK'i Transit'e coz dur, veriyi yerelde coz, karsilastir.
    dec = post(f"/v1/{MOUNT}/decrypt/{KEY}", {"ciphertext": wrapped}, token,
               fail_rc=RC_PHASE_B_DEC)
    dek2_b64 = (dec.get("data") or {}).get("plaintext", "")
    if not dek2_b64:
        print("FAIL: B wrapped DEK cozulemedi", flush=True)
        raise SystemExit(RC_PHASE_B_DEC)
    dek2 = base64.b64decode(dek2_b64)
    try:
        plain = AESGCM(dek2).decrypt(nonce, ct, aad)
    except Exception:
        print("FAIL: B yerel cozme basarisiz (tag/nonce/AAD uyusmadi)", flush=True)
        raise SystemExit(RC_PHASE_B_DEC)
    finally:
        del dek2
    if not hmac.compare_digest(plain, PAYLOAD):
        print("FAIL: B round-trip eslesmedi", flush=True)
        raise SystemExit(RC_PHASE_B_DEC)
    print("B: decrypt OK round-trip eslesti", flush=True)


def main() -> int:
    token = phase_a_login()
    phase_a_roundtrip(token)
    phase_b_envelope(token)
    print("ENVELOPE PASS", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:
        # Beklenmeyen hata (baglanti/timeout/parse): faz kodlariyla cakismaz.
        print(f"FAIL: beklenmeyen hata: {type(e).__name__}", flush=True)
        sys.exit(RC_UNEXPECTED)
