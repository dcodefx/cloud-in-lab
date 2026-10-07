# OpenBao Tests

> Scope: **all live verification tests** for OpenBao — procedure (command +
> expected + result) and actual output. Architectural narrative and evidence logs
> live in the relevant primary document; only test procedures are kept here.
>
> **This document serves as a template for new sections.** To add a new topic:
> `## Section N — <topic>` heading → `### Prerequisites` → for each test
> `### Test M — <what is checked>` with **question / command / Expected /
> Result (YYYY-MM-DD)** underneath. Test numbers continue uninterrupted across
> the document (Section 1: Tests 1–4, Section 2: Tests 5–13, Section 3: Templating pilot).

## Section 1 — Transit Envelope Engine and Operation (F2.6)

> Scope: live verification procedures and results for the `transit-envelope-b` Job.
> Architectural narrative and evidence logs are in `openbao-architecture-guide.md §6.2`; procedure (command + expected + result) is kept here.

### Prerequisites

- The Job must have run and returned `ENVELOPE PASS` (`kubectl -n transit-demo logs job/transit-envelope-b`).
- Admin token (ops-admin AppRole, from the controller):
  ```bash
  cd ansible
  ROLE=$(jq -r .role_id outputs/openbao/ops-admin.json)
  SECRET=$(jq -r .secret_id outputs/openbao/ops-admin.json)
  ADMIN=$(curl -sk -X POST https://164.102.98.186:8200/v1/auth/approle/login \
    -d "{\"role_id\":\"$ROLE\",\"secret_id\":\"$SECRET\"}" | jq -r .auth.client_token)
  ```

### Test 1 — Negative 403

Is an unauthorized decrypt request blocked?

```bash
curl -sk -X POST https://164.102.98.186:8200/v1/transit/decrypt/transit-envelope-b-app-key \
  -d '{"ciphertext":"vault:v1:AAA"}' -w "\nHTTP:%{http_code}\n"
```

- Expected: `{"errors":[" permission denied"]}`, HTTP 403.
- Result (2026-09-16): ✅ `permission denied`, HTTP 403.

### Test 2 — No plaintext in audit

Is sensitive data not written to the audit disk? (On LXC CT 301.)

```bash
grep -c "transit-demo-B-envelope" /var/log/bao/audit.log
# Expected: 0
grep "datakey" /var/log/bao/audit.log | head -3
# Expected: request lines present; token/plaintext/ciphertext fields masked with hmac-sha256
```

- Result (2026-09-16): ✅ count 0; secret fields masked.
- Bonus evidence: `metadata.scope: transit-envelope-b`, `token_type: batch, ttl: 1800` — matches the profile catalog exactly.

### Test 3 — Rotate

Do old envelopes survive a key rotation?

```bash
curl -sk -o /dev/null -w "rotate HTTP:%{http_code}\n" -X POST \
  https://164.102.98.186:8200/v1/transit/keys/transit-envelope-b-app-key/rotate \
  -H "X-Vault-Token: $ADMIN"
# Expected: rotate HTTP:200

curl -sk https://164.102.98.186:8200/v1/transit/keys/transit-envelope-b-app-key \
  -H "X-Vault-Token: $ADMIN" | jq .data.latest_version
# Expected: 2

curl -sk -X POST https://164.102.98.186:8200/v1/transit/decrypt/transit-envelope-b-app-key \
  -H "X-Vault-Token: $ADMIN" -d '{"ciphertext":"<old-wrapped>"}' \
  | jq -r '.data.plaintext | length'
# Expected: 44 (= base64(32B) — old envelope decrypted)
```

- Result (2026-09-16): ✅ HTTP 200, `latest_version: 2`, old wrapped decrypted (44).

### Test 4 — Second-run idempotency

Is nothing overwritten on a repeat run?

```bash
ansible-playbook -i inventory/k8s.ini.generated playbooks/k8s_apps.yml --tags apps
```

- Expected: `Scope 'transit-envelope-b' zaten OpenBao KV'de mevcut, OpenBao adımları atlanıyor` + `failed=0`.
- Result: ✅ expected warning printed, OpenBao steps skipped, `failed=0` (observed repeatedly across user runs).

---

## Section 2 — Raft Snapshot Agent (B10/B11)

> Scope: live verification of the `bao-raft-agent` service. Authority definition
> is in `openbao-rbac.md §3` (P5/B10 + P6/B11), config/unit in
> `roles/openbao/server/templates/bao-raft-agent.{hcl,service}.j2`,
> deployment in `roles/openbao/server/tasks/backup.yml`.
>
> ℹ️ **About the Expected column:** this section was written during debugging, *after*
> the fix. That is, the "Expected" values were derived backwards from observation.
> This section's regression value lies in the `Expected` rows: if a future
> installation deviates, this is the comparison point.

### Prerequisites

- `openbao_backup_enabled: true` (default) and `roles/openbao/server/tasks/backup.yml` must have run → `bao-raft-agent.service` + `/etc/bao/agent.sock`.
- CT 301 = `openbao-1` = `164.102.98.186`. LXC management via `root` + `~/.ssh/id_ed25519`.
- **No command uses a token.** The agent's `api_proxy` + `auto_auth`
  authority takes effect; only the agent knows the token.
- For convenience, the `bao` client is run over the agent socket:
  ```bash
  export BAO_ADDR=unix:///etc/bao/agent.sock
  export BAO_SKIP_VERIFY=true
  B=/usr/local/bin/bao
  ```
  (`BAO_SKIP_VERIFY` is mandatory: the server TLS is **self-signed**
  via `openssl req -x509` — `configure.yml:2`. The same variable is also used in `init.yml`.)

### Test 5 — Is the service active and enabled?

Is the unit installed, and will it run at boot too?

```bash
systemctl is-active bao-raft-agent
systemctl is-enabled bao-raft-agent
```

- Expected: `active` and `enabled`.
- Result (2026-09-28): ✅ `active` / `enabled`.

### Test 6 — Is the socket created, who owns it?

Can the unix listener actually create the file? (`ProtectSystem` regression
point — see the "Known bug" section below.)

```bash
ls -l /etc/bao/agent.sock
```

- Expected: socket file present, owned by `bao:bao`.
- Result (2026-09-28): ✅ `srwxr-xr-x 1 bao bao 0 Sep 28 12:19 /etc/bao/agent.sock`

### Test 7 — Tokenless connection (is auto_auth working?)

Is OpenBao reachable over the socket alone, with no token carried?

```bash
BAO_ADDR=unix:///etc/bao/agent.sock BAO_SKIP_VERIFY=true /usr/local/bin/bao status
```

- Expected: `Sealed: false`, `Initialized: true` — **no token**.
- Result (2026-09-28): ✅
  ```
  Key                     Value
  ---                     -----
  Seal Type               shamir
  Initialized             true
  Sealed                  false
  Total Shares            5
  Threshold               3
  Version                 2.6.2
  ```

### Test 8 — Auto-auth and renewal (journal evidence)

Was identity obtained, was the renewal loop established? A successful restart
with `Type=notify` is also indirect evidence (the unit cannot become `active`
without the agent sending `READY=1`).

```bash
journalctl -u bao-raft-agent --no-pager -n 12 \
  | grep -iE "auth|error|warn|listener|ready|token"
```

- Expected: `authentication successful` + `starting renewal process` +
  `renewed auth token`.
- Result (2026-09-28): ✅
  ```
  Sep 28 12:19:24 openbao-1 bao[8059]: [INFO]  agent.auth.handler: authenticating
  Sep 28 12:19:24 openbao-1 bao[8059]: [INFO]  agent.auth.handler: authentication successful, sending token to sinks
  Sep 28 12:19:24 openbao-1 bao[8059]: [INFO]  agent.auth.handler: starting renewal process
  Sep 28 12:19:24 openbao-1 bao[8059]: [INFO]  agent.auth.handler: renewed auth token
  ```
- Note: Renewal lives inside `bao agent`; `backup-openbao.sh` contains **no
  token-renewal code**. Long-lived/non-expiring token requests are therefore
  declined (see `openbao-rbac.md §3` — only root issues non-expiring tokens).

### Test 9 — P5 READ: can the profile read the raft snapshot?

The `bao-raft-agent` policy holds `sys/storage/raft/snapshot` → `read`.

```bash
BAO_ADDR=unix:///etc/bao/agent.sock BAO_SKIP_VERIFY=true \
  /usr/local/bin/bao read sys/storage/raft/snapshot
```

- Expected: authorization **passes**; the server returns the raft data.
- Result (2026-09-28): ✅
  ```
  Error reading sys/storage/raft/snapshot: invalid character '\x1f' looking for beginning of value
  ```
- ⚠️ **This is a PASS, not an error.** A raft snapshot is a **compressed binary
  stream**; `0x1f` is the first byte of the gzip magic number (`1f 8b`). The
  server returned the data; only the CLI failed to convert it to JSON. **This
  exact output is the expected behavior** — had authority been denied, `403 permission denied` would have appeared.

### Test 10 — P5 WRITE: can the profile not write? (the real conformance test)

The critical check. An always-on service must not **write back** the raft store.

```bash
BAO_ADDR=unix:///etc/bao/agent.sock BAO_SKIP_VERIFY=true \
  /usr/local/bin/bao write sys/storage/raft/snapshot path=/tmp/conformance-probe.snap
```

- Expected: `403 permission denied` (PASS = denied).
- Result (2026-09-28): ✅
  ```
  Error writing data to sys/storage/raft/snapshot: Error making API request.

  URL: PUT http://localhost/v1/sys/storage/raft/snapshot
  Code: 403. Errors:
  ```
- Note: Had the profile been able to write, this command would have **created** a snapshot — i.e. an authority bug
  would have surfaced not as data corruption but as silent over-privilege.

### Test 11 — Token catalog: which policies?

```bash
BAO_ADDR=unix:///etc/bao/agent.sock BAO_SKIP_VERIFY=true \
  /usr/local/bin/bao token lookup | grep -iE "policies|renewable|display_name"
```

- Expected: policies `[bao-raft-agent default]`, renewable.
- Result (2026-09-28): ✅
  ```
  display_name         approle
  policies             [bao-raft-agent default]
  renewable            true
  ```
- Note: the `default` policy is the **empty (deny-by-default)** policy OpenBao
  attaches to every token automatically. Test 12 below proves this.

### Test 12 — Is the `default` policy empty? (deny-by-default proof)

Does the `default` policy contain any hidden authority?

```bash
BAO_ADDR=unix:///etc/bao/agent.sock BAO_SKIP_VERIFY=true \
  /usr/local/bin/bao policy read default
```

- Expected: `403` — the policy is unreadable, i.e. it grants no authority.
- Result (2026-09-28): ✅
  ```
  Error reading policy named default: Error making API request.

  URL: GET http://localhost/v1/sys/policies/acl/default
  Code: 403. Errors:

  * 1 error occurred:
  	* permission denied
  ```

### Test 13 — Is `socket_mode` actually applied? (Unexpected finding)

The config says `socket_mode = "0660"`. What actually happens?

```bash
stat -c '%n  mode=%A  octal=%a  owner=%U:%G' /etc/bao/agent.sock
stat -c '%n mode=%a owner=%U:%G' /etc/bao
systemctl show bao-raft-agent -p UMask --value
```

- Expected: socket `0660`.
- Result (2026-09-28): ❌ **socket `0755`** — the agent does **not apply** `socket_mode`.
  ```
  /etc/bao/agent.sock  mode=srwxr-xr-x  octal=755  owner=bao:bao
  /etc/bao mode=750 owner=bao:bao
  0022
  ```
  `0755` = `0777 & ~umask(0022)` — the socket was created with defaults,
  the mode never applied.
- **Security still holds, but on different grounds:** the socket's directory
  `/etc/bao` = `0750 bao:bao`. Since only `root` and the `bao` group can enter
  the directory, access to the socket is effectively restricted.
- 🔴 **Result: today protection comes from the DIRECTORY permission, not from `socket_mode`.**
  If `/etc/bao` is loosened below 0750, the socket opens up too. The
  `bao-raft-agent.hcl.j2` comment was updated with this measurement.
- Verification source: `openbao.org/docs/configuration/listener/unix` →
  `socket_mode (string: "", <optional>)` — the type is correct, this is not a type issue;
  the behavior is missing in OpenBao 2.6.2.

### Known bug and root cause (regression note)

The tests in this section were made possible by fixing the failure below. If those hardening lines are re-applied,
the service will not stay up.

**Symptom:** `bao-raft-agent.service` in a constant restart loop, on every attempt

```
bao[...]: Error fetching client: failed to get token helper: open /home/bao/.bao: permission denied
systemd[1]: bao-raft-agent.service: Main process exited, code=exited, status=1/FAILURE
```

**Root cause — all three come from the hardening block copied from `bao.service`:**

| # | Cause | Symptom | Fix |
|---|---|---|---|
| 1 | `ProtectHome=yes` → `/home` unreachable in the mount namespace. While initializing the client, `bao agent` reads the CLI config directory (`$HOME/.bao`) → `EACCES` → `exit 1` | the **first** error in the log | `ProtectHome=yes` **removed** |
| 2 | `ProtectSystem=full` → `/etc` read-only → the unix listener **cannot write** the `/etc/bao/agent.sock` file | surfaces once 1 is fixed | `ProtectSystem=full` + `ReadWritePaths=` **removed** |
| 3 | The server TLS is self-signed via `openssl req -x509`; the agent config has no `tls_skip_verify`/`BAO_SKIP_VERIFY` | surfaces once 2 is fixed | `Environment=BAO_SKIP_VERIFY=true` **added** |

**Why cause 1 only blows up in the agent:** `bao server` never touches the `~/.bao` directory
— no problem arises. `bao agent`, however, must read it while initializing the client.
The official `openbao-snapshot-agent` unit (`docs/vm-configuration.md`) holds **none** of these three
hardening lines; only filesystem-neutral directives like `NoNewPrivileges`, `PrivateTmp`,
and `LimitNOFILE` are retained.

**Post-fix verification:**

```bash
grep -nE '^(Protect|ReadWrite)' /etc/systemd/system/bao-raft-agent.service
# Expected: empty output (no hardening)
grep -E 'NoNewPrivileges|PrivateTmp|LimitNOFILE' /etc/systemd/system/bao-raft-agent.service
# Expected: all three present
grep BAO_SKIP_VERIFY /etc/systemd/system/bao-raft-agent.service
# Expected: Environment=BAO_SKIP_VERIFY=true
```

Playbook result (2026-09-28):

```
localhost                  : ok=2    changed=0    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0
openbao-1                  : ok=86   changed=19   unreachable=0    failed=0    skipped=23   rescued=0    ignored=0
```

---

## Section 3 — Identity Templating Pilot (2026-09-10)

> Purpose: live verification of `identity.entity.aliases.<accessor>.metadata.scope`-based policy templates. Comprehensive reference: [`openbao-rbac.md`](openbao-rbac.md) §5.

### Prerequisites

- OpenBao 2.6.2 up and unsealed; the `ops-admin` credential present on the controller.
- Pilot resources (role, policy, KV data) fully deleted at test end.

### Test P-1 — Alias metadata visibility

On the `transit-demo` role, a secret-id was issued with `metadata='{"scope": "pilot-app"}'` (JSON-string), a login was performed, and `identity/entity` was read.

- **Expected:** `scope: pilot-app` visible inside the alias metadata.
- **Result (PASS):** `{'role_name': 'transit-demo', 'scope': 'pilot-app'}` — custom metadata is copied to the alias; templating is usable.
- **Cleanup:** secret-id deleted via `secret-id-accessor/destroy`. Note: `secret-id/destroy` does not accept an accessor (returns "missing secret_id"); `revoke-self` returns an empty 204.

### Test P-2 — Scope isolation under a single static policy

A single `workload-reader-templated` policy + two pilot roles (`rbac-pilot-a/b`, TTL 10m) + KV test data.

- **Expected (4 checks):** A→own 200, A→B 403, B→own 200, B→A 403.
- **Result (PASS):** 4/4 held.
- **Fix (caught live):** `sys/auth` returns the accessor with a prefix (`auth_approle_<id>`). If an extra `auth_approle_` prefix is placed on the HCL key, the key becomes `auth_approle_auth_approle_<id>` and the policy silently returns 403 (positive test included). The correct key is the accessor itself; the Ansible fact is simplified with `regex_replace('^auth_approle_', '')`.
- **Cleanup:** token revoke + secret-id destroy + role/policy/KV deletion (full).

### Upstream research note — OpenBao Discussion #2212

Upstream discussion (December 2025, closed), distinguishing proven from unproven:

- **Proven:** `entity.name` does not work in AppRole (403, with transcript); the working form embeds the mount accessor in the literal (mount maintenance burden); template instantiations have no debug path (confirmed by collaborator eyenx); the recommended pattern is generating policy per approle in code (= the project's render design).
- **Unproven:** the secret-ids in the discussion were issued without metadata (`-force`, parameterless) — the visible `role_name` is a value the login mechanism writes automatically; that custom `scope` metadata is copied to the alias does not follow from that record. Test P-1 closed this gap.
