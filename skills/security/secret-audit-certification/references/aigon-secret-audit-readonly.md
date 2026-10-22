# AIGON <workspace> — read-only secret audit (worked recipe + measured results)

Session: 2026-10-12. Ask: "Audyt sekretów: czy każdy sekret ma kanoniczną
ścieżkę Vault→env, nie ma hardcoded credentiali." Verdict: **no hardcoded
credentials; all secrets on canonical Vault→env path.** No files modified.

## Layout facts (verify per session, don't assume)
- Repo root: `<workspace>` (prod-stack). Runtime code = `runtime/crates/*` + `router/`
  — **there is no `runtime/src/`**.
- Secret registry (tracked): `config/secrets.yaml`. Actual secret files:
  `config/secrets/*` (untracked/git-ignored).
- Per-product clones also carry `config/canonical/credentials.yaml` +
  `tools/verify/security/credentials.sh` (Prod-template-canon, sigil).

## Gate results (this run)
```
bash tools/gates/law-56a-secret-channel.sh  → LAW-56a PASS — 0 w zakazanych kanałach (argv/ssh/historia/transkrypty)
bash tools/gates/leaks-permissions.sh       → GATE-133 PASS — 16 ścieżek (4 kat. + 12 plików), 0 z bitami świata
bash tools/gates/secrets-staged.sh          → secrets-staged: PASS
bash tools/verify/security/credentials.sh   → TIMEOUT >180s (queries Vault/network) → rerun under `timeout 120`
```

## config/secrets.yaml — canonical field proof
```
TOP-LEVEL: ['vault', 'secrets']          # vault{addr,mount,kv_version,token_source}
secrets: list of 140 entries
field-set histogram:
  118 x {description, env_name, field, nodes, targets, vault_path}
   13 x {env_name, field, nodes, targets, vault_path}
    6 x {description, env_name, field, nodes, raw, targets, vault_path}
    3 x {env_name, field, nodes, raw, targets, vault_path}
fields beyond canonical: []   ← PASS (no value-bearing field)
```
`raw` = int flag (all 9 raw entries: raw_type=int, non-empty) — NOT a value.

## Hardcoded-credential sweep — measured
- `scripts/` + `config/`: 5 literal matches, ALL false positives:
  - `scripts/wiring-doctor.py:150,232` → `token = "wiring-" + uuid.uuid4().hex[:16]`
  - `scripts/aigon-lane-check.py:221`  → `token = 'AIGON_' + secrets.token_hex(8)`
  - `scripts/sync-agent-models.py:1999`→ `want_api_key = "aigon-local"` (placeholder default)
  - `scripts/hybrid-proxy.py:89`       → `token = ""`
  - `config/canonical/rr710-remote-access.yaml:28` → `unattended_password: set_and_reconnect_verified` (status string)
- Rust `runtime/crates` + `router/`: 1 match = rustdoc `//! api_key: "your-api-key"`.
- Entropy scan (194 raw hits): paths, CF ruleset IDs, `BIN_PIN=<sha256>` (integrity
  pin), public OAuth `client_id` UUID (`scripts/hybrid-proxy.py:140`), signer path.
  → **0 real secrets**.
- Rust `env::var(...).unwrap_or("literal")` / `unwrap_or_else(|| "...")`: **0**.
- `config/secrets/*`: 0 world-readable (all `640 aigon:aigon`, one `600 root`);
  git-ignored. Root `.env` git-ignored. `config/canonical/credentials.yaml` = placeholders only.
- 109 scripts reference Vault (`VAULT_ADDR` / `vault kv get` / `secrets.yaml`).

## Portable command block
```bash
cd <workspace>
# field-set proof
python3 -c "import yaml; d=yaml.safe_load(open('config/secrets.yaml'))
allowed={'vault_path','field','env_name','nodes','targets','raw','description'}
extra=set(); [extra.update(e) for e in d['secrets'] if isinstance(e,dict)]
print('fields beyond canonical:', sorted(extra-allowed))"
# masked literal sweep
grep -rInE '(password|passwd|secret|api[_-]?key|token)[[:space:]]*[:=][[:space:]]*"[^"$`<{][^"]{3,}"' \
  scripts/ config/ runtime/crates router/ 2>/dev/null \
  | grep -viE '\.bak|example|PLACEHOLDER|REDACTED|xxx|test-|dummy|fixture|\$\{|\$\(|change[_-]?me|your[_-]' \
  | sed -E 's/([:=][[:space:]]*).{4,}$/\1<MASKED>/' | awk -F: '{print $1":"$2}' | sort | uniq -c | sort -rn
# rust fallback count
grep -rInE 'env::var[^;]*\.unwrap_or(_else)?\([[:space:]]*("|Some\(")' runtime/crates router/ | wc -l
# perms
find config/secrets -maxdepth 1 -type f -perm -o+r | wc -l
```
