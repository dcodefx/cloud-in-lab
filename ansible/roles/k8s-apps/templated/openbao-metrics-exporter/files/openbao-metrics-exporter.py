#!/usr/bin/env python3
"""
openbao-metrics-exporter.py — OpenBao /v1/sys/metrics'i ve /v1/sys/health
durumunu Prometheus icin plain (auth'suz) bir :9090/metrics endpoint'inde
birlestirir.

Tasarim (connectivity.py ile ayni felsefe — stdlib-only, self-service
credential akisi):
  1. /mnt/approle/role_id + /mnt/approle/secret_id oku (CSI/tmpfs, K8s
     Secret'a hic yazilmiyor).
  2. auth/approle/login ile token al; token, lease suresi dolmadan once
     kendi kendine yenilenir (renew-self), olmazsa yeniden login denenir.
     Bu dongu HATA TOLERANSLIDIR — sealed durumda basarisiz olsa bile
     sunucu process'i CALISMAYA DEVAM EDER, tekrar tekrar dener.
  3. HealthState, /v1/sys/health'i (auth GEREKTIRMEYEN endpoint, sealed
     olsa bile 503 ile ama YANIT VERIR) ayri, bagimsiz bir dongude
     periyodik olarak sorgular.
  4. :9090/metrics her istekte UCU BIRLESTIRIR:
       - HealthState (her zaman var, token'a bagli degil)
       - exporter'in kendi self-metrigi (her zaman var)
       - sys/metrics (best-effort — sealed/token yoksa bu kisim atlanir,
         ama response YINE DE 200 doner, diger iki blok kaybolmaz)

Prometheus tarafinda HICBIR token/auth mantigi gerekmez.
"""

import json
import logging
import os
import ssl
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [%(levelname)s] %(message)s",
)
log = logging.getLogger("openbao-metrics-exporter")

OPENBAO_ADDR = os.environ["OPENBAO_ADDR"]              # ör: https://164.102.98.186:8200
APPROLE_ROLE_ID_PATH = os.environ.get("APPROLE_ROLE_ID_PATH", "/mnt/approle/role_id")
APPROLE_SECRET_ID_PATH = os.environ.get("APPROLE_SECRET_ID_PATH", "/mnt/approle/secret_id")
CA_BUNDLE_PATH = os.environ.get("CA_BUNDLE_PATH", "")   # bos ise verify kapali (demo/self-signed)
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9090"))
METRICS_CACHE_SECONDS = int(os.environ.get("METRICS_CACHE_SECONDS", "10"))
HEALTH_CHECK_SECONDS = int(os.environ.get("HEALTH_CHECK_SECONDS", "15"))
RENEW_AT_FRACTION = 0.7  # lease suresinin yuzde kaci gecince renew denensin

# ---------------------------------------------------------------------------
# TLS context
# ---------------------------------------------------------------------------
def build_ssl_context() -> ssl.SSLContext:
    if CA_BUNDLE_PATH and os.path.isfile(CA_BUNDLE_PATH):
        return ssl.create_default_context(cafile=CA_BUNDLE_PATH)
    # CA bundle verilmediyse: public API ile verify kapatma (private
    # ssl._create_unverified_context() yerine)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    log.warning("CA bundle verilmedi — TLS dogrulamasi KAPALI. Prod icin CA_BUNDLE_PATH set edin.")
    return ctx


SSL_CTX = build_ssl_context()


# ---------------------------------------------------------------------------
# Token state — self-service login + renew
# ---------------------------------------------------------------------------
class TokenState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.client_token: str | None = None
        self.lease_duration: int = 0
        self.issued_at: float = 0.0

    def set(self, token: str, lease_duration: int) -> None:
        with self._lock:
            self.client_token = token
            self.lease_duration = lease_duration
            self.issued_at = time.time()

    def get(self) -> str | None:
        with self._lock:
            return self.client_token

    def seconds_until_renew(self) -> float:
        with self._lock:
            if not self.client_token or self.lease_duration <= 0:
                return 0.0
            elapsed = time.time() - self.issued_at
            renew_at = self.lease_duration * RENEW_AT_FRACTION
            return max(0.0, renew_at - elapsed)


STATE = TokenState()


def _bao_request(method: str, path: str, token: str | None = None, body: dict | None = None) -> dict:
    url = f"{OPENBAO_ADDR}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("X-Vault-Token", token)
    with urllib.request.urlopen(req, context=SSL_CTX, timeout=10) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def approle_login() -> None:
    with open(APPROLE_ROLE_ID_PATH) as f:
        role_id = f.read().strip()
    with open(APPROLE_SECRET_ID_PATH) as f:
        secret_id = f.read().strip()
    resp = _bao_request(
        "POST", "/v1/auth/approle/login",
        body={"role_id": role_id, "secret_id": secret_id},
    )
    auth = resp["auth"]
    STATE.set(auth["client_token"], auth.get("lease_duration", 3600))
    log.info("AppRole login basarili, lease_duration=%ss", auth.get("lease_duration"))


def renew_self() -> bool:
    token = STATE.get()
    if not token:
        return False
    try:
        resp = _bao_request("POST", "/v1/auth/token/renew-self", token=token)
        auth = resp["auth"]
        STATE.set(auth["client_token"], auth.get("lease_duration", 3600))
        log.info("Token yenilendi, lease_duration=%ss", auth.get("lease_duration"))
        return True
    except (urllib.error.HTTPError, KeyError) as e:
        log.warning("Renew basarisiz (%s)", e)
        return False


def token_refresh_loop() -> None:
    """
    Hata-toleransli dongu — OpenBao sealed/erisilemez olsa bile bu thread
    ASLA olmez, sadece bekleyip tekrar dener. Server'in ayakta kalmasi
    buna bagli DEGIL (bkz. main()).
    """
    while True:
        try:
            if not STATE.get():
                approle_login()
            elif STATE.seconds_until_renew() <= 0:
                if not renew_self():
                    approle_login()
        except Exception as e:
            log.warning("Token islemi basarisiz (muhtemelen sealed/erisilemez): %s", e)
            time.sleep(10)
            continue
        time.sleep(max(STATE.seconds_until_renew(), 5))


# ---------------------------------------------------------------------------
# Health state — /v1/sys/health, AUTH GEREKTIRMEZ, sealed'ken de yanit verir
# ---------------------------------------------------------------------------
class HealthState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.sealed: int = 1         # varsayim: bilmiyoruz = sealed kabul et (guvenli taraf)
        self.initialized: int = 0
        self.standby: int = 0
        self.up: int = 0

    def _check(self) -> None:
        req = urllib.request.Request(f"{OPENBAO_ADDR}/v1/sys/health")
        try:
            with urllib.request.urlopen(req, context=SSL_CTX, timeout=5) as resp:
                code = resp.status
        except urllib.error.HTTPError as e:
            # 503=sealed, 429=standby, 501=uninit, 472/473=DR/perf standby — HEPSI "erisilebilir"
            code = e.code
        except Exception as e:
            log.warning("sys/health erisilemedi: %s", e)
            with self._lock:
                self.up = 0
            return

        with self._lock:
            self.up = 1
            self.sealed = 1 if code == 503 else 0
            self.standby = 1 if code in (429, 472, 473) else 0
            self.initialized = 0 if code == 501 else 1

    def render(self) -> bytes:
        with self._lock:
            sealed, initialized, standby, up = self.sealed, self.initialized, self.standby, self.up
        return (
            "# HELP openbao_up OpenBao sys/health endpoint erisebilirligi\n"
            "# TYPE openbao_up gauge\n"
            f"openbao_up {up}\n"
            "# HELP openbao_sealed OpenBao sealed durumu (1=sealed, 0=unsealed)\n"
            "# TYPE openbao_sealed gauge\n"
            f"openbao_sealed {sealed}\n"
            "# HELP openbao_initialized OpenBao initialized durumu\n"
            "# TYPE openbao_initialized gauge\n"
            f"openbao_initialized {initialized}\n"
            "# HELP openbao_standby OpenBao standby durumu\n"
            "# TYPE openbao_standby gauge\n"
            f"openbao_standby {standby}\n"
        ).encode()


HEALTH = HealthState()


def health_check_loop() -> None:
    while True:
        HEALTH._check()
        time.sleep(HEALTH_CHECK_SECONDS)


# ---------------------------------------------------------------------------
# sys/metrics cache — best-effort, token gerektirir, sealed'ken basarisiz
# olabilir. Bu BASARISIZLIK response'un TAMAMINI etkilemez (bkz. do_GET).
# ---------------------------------------------------------------------------
class MetricsCache:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._body: bytes = b""
        self._fetched_at: float = 0.0
        self.last_success: float = 0.0

    def get(self) -> bytes:
        with self._lock:
            if time.time() - self._fetched_at < METRICS_CACHE_SECONDS and self._body:
                return self._body
        body = self._fetch()
        with self._lock:
            self._body = body
            self._fetched_at = time.time()
            self.last_success = time.time()
        return body

    def _fetch(self) -> bytes:
        token = STATE.get()
        if not token:
            raise RuntimeError("Henuz gecerli bir token yok")
        url = f"{OPENBAO_ADDR}/v1/sys/metrics?format=prometheus"
        req = urllib.request.Request(url)
        req.add_header("X-Vault-Token", token)
        with urllib.request.urlopen(req, context=SSL_CTX, timeout=10) as resp:
            return resp.read()

    def exporter_self_metric(self) -> bytes:
        return (
            "# HELP openbao_metrics_exporter_last_success_timestamp_seconds "
            "Son basarili sys/metrics cekme zamani (unix epoch)\n"
            "# TYPE openbao_metrics_exporter_last_success_timestamp_seconds gauge\n"
            f"openbao_metrics_exporter_last_success_timestamp_seconds {self.last_success}\n"
        ).encode()


METRICS_CACHE = MetricsCache()


# ---------------------------------------------------------------------------
# HTTP handler — uc bloğu birleştirir, sys/metrics basarisiz olsa da
# HER ZAMAN 200 + health/self metrikleriyle doner.
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        parts = [HEALTH.render(), METRICS_CACHE.exporter_self_metric()]
        try:
            parts.append(METRICS_CACHE.get())
        except Exception as e:
            log.warning("sys/metrics alinamadi (muhtemelen sealed), health ile devam: %s", e)

        body = b"".join(parts)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        pass


def main() -> None:
    threading.Thread(target=health_check_loop, daemon=True).start()
    threading.Thread(target=token_refresh_loop, daemon=True).start()

    # Server, token/health beklemeden HEMEN ayaga kalkar — sealed durumda
    # bile pod "Ready" olur ve openbao_sealed=1 gibi kritik sinyali verir.
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    log.info("Dinleniyor :%s/metrics", LISTEN_PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
