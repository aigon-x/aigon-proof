---
name: secret-audit-certification
description: >-
  READ-ONLY audit/certification that every secret has a canonical Vault→env
  path and there are no hardcoded credentials in a repo (scripts, configs, Rust
  runtime). Value-masking grep discipline, false-positive taxonomy, AIGON gate
  trio, and canonical-proof commands. Użyj przy "audyt sekretów", "hardcoded
  credentials", "czy każdy sekret ma ścieżkę Vault→env".
---


# Secret Audit — Read-Only Certification

Certify (not remediate) that a repo's secrets all flow through a canonical
Vault→env channel and that no hardcoded credentials exist. Delivers PASS/FAIL
per question with evidence, NONDESTRUCTIVE — changes nothing.

**When to use:** "audyt sekretów", "czy każdy sekret ma kanoniczną ścieżkę
Vault→env", "nie ma hardcoded credentiali", pre-release secret hygiene check,
re-verification after a leak remediation. (For finding AND migrating secrets to
Vault, that's a different class — see related skills below.)

## Non-negotiable rules

1. **ZERO plaintext secret values in the report/transcript/log.** Mask every
   grep hit; report only `file:line` + key name. Never `cat` a secret file.
2. **READ-ONLY.** No edits, no migrations, no rotate. If the ask drifts to
   remediation, stop and confirm scope.
3. **No PASS without evidence.** Each "PASS" cites the command output that
   produced it. Absent/unmeasured ≠ green.
4. **Classify before reporting.** Grep on credential keywords produces noise —
   see the false-positive taxonomy; only report high-entropy real credentials.

## Step 1 — Fast verdict: the AIGON gate trio

Run first; produces an evidence-backed PASS/FAIL without touching anything.
`cd <workspace>` and:
```bash
bash tools/gates/law-56a-secret-channel.sh   # LAW-56a: secrets in argv/ssh/history/agent-transcripts → 0 = PASS
bash tools/gates/leaks-permissions.sh        # GATE-133: world-readable secret/PII paths → 0 = PASS
bash tools/gates/secrets-staged.sh           # secrets in git staging → PASS
```
rc 0 = PASS, rc >0 = violation. `tools/verify/security/credentials.sh` is the
full credential-registry gate and **may query Vault/network — wrap it in
`timeout 120`** so it can't block the whole turn.

## Step 2 — Canonical Vault→env proof

Prove the mapping exists WITHOUT reading values by asserting the allowed FIELD
SET. In this repo `config/secrets.yaml` entries carry only canonical keys:
```bash
python3 -c "import yaml; d=yaml.safe_load(open('config/secrets.yaml'))
allowed={'vault_path','field','env_name','nodes','targets','raw','description'}
extra=set(); [extra.update(e) for e in d['secrets'] if isinstance(e,dict)]
print('fields beyond canonical:', sorted(extra-allowed))"   # must be []
```
- `vault_path` → `field` → `env_name` is the canonical channel.
- **`raw` is an int FLAG, not a value** — do not treat its presence as a leak.
- A value-bearing field (e.g. `value`, `secret`) is the violation.
- `config/canonical/credentials.yaml` = placeholder registry (name/owner/
  rotation_date/status), no values — that's correct by design.

## Step 3 — Hardcoded-credential probes

```bash
# (a) script/config literals — MASK values before they reach the transcript
grep -rInE '(password|passwd|secret|api[_-]?key|token)[[:space:]]*[:=][[:space:]]*"[^"$`<{][^"]{3,}"' \
  scripts/ config/ runtime/crates router/ 2>/dev/null \
  | grep -viE '\.bak|example|PLACEHOLDER|REDACTED|xxx|test-|dummy|fixture|\$\{|\$\(|change[_-]?me|your[_-]' \
  | sed -E 's/([:=][[:space:]]*).{4,}$/\1<MASKED>/' | awk -F: '{print $1":"$2}' | sort | uniq -c | sort -rn

# (b) Rust env::var with a hardcoded literal fallback — count MUST be 0
grep -rInE 'env::var[^;]*\.unwrap_or(_else)?\([[:space:]]*("|Some\(")' runtime/crates router/ | wc -l

# (c) file perms: 0 world-readable secret files expected
find config/secrets -maxdepth 1 -type f -perm -o+r | wc -l

# (d) are secret dirs/files git-ignored? tracked secrets = ESCALATE
git check-ignore .env config/secrets/<any-file>
git ls-files | grep -iE '\.env$|secrets\.yaml$|\.pem$|\.key$|credentials'
```
Note: in the AIGON repo the runtime code lives in `runtime/crates/*` and
`router/` (there is no `runtime/src/`).

## Step 4 — False-positive taxonomy (classify, then DISCARD)

These are NOT findings — they dominate raw grep output:
- generated-token **prefixes**: `token = "wiring-" + uuid.uuid4().hex[:16]`, `'AIGON_' + secrets.token_hex(8)`
- **placeholder defaults**: `want_api_key = "aigon-local"`, `token = ""`
- **status strings** masquerading as creds: `unattended_password: set_and_reconnect_verified`
- **public OAuth `client_id`** (a UUID) — public by spec, not a credential
- **integrity pins**: `BIN_PIN="<sha256 hex>"`, signer/pubkey paths, CF ruleset IDs
- **doc comments**: `//! api_key: "your-api-key"` rustdoc samples

Report a hit as a finding ONLY if: high entropy AND key names a real credential
AND it is not a path / status / hash / id / doc sample.

## Reporting shape

Answer the two asked questions directly and separately:
1. **Hardcoded credentials?** → number of REAL findings (and note false-positive counts).
2. **Every secret on canonical Vault→env path?** → field-set proof (must be `[]`) + file-perm count (must be 0).
Include: gate results with rc, any unmeasured channels, and any gate that timed
out (state it — do not silently drop it). List any borderline non-secrets
(public client_id, integrity pin) explicitly as "not a secret, noted".

## Related skills (overlap — curator may consolidate)

- `credential-security-sweep` — find-ALL + remediate/migrate to Vault (manually authored, patch-blocked)
- `secret-mesh-audit-and-vault` — multi-node discovery sweep + Vault design (manually authored, patch-blocked)
- `hardcoded-credential-extermination` — replace hardcoded defaults in Rust
- `secrets-management` — general secrets policy (synced from SSOT; do not edit)

## References

- `references/aigon-secret-audit-readonly.md` — full worked recipe + measured results for <workspace>.

## Pitfalls

- **Don't `cat` a secret file to inspect a hit.** Mask via `sed` or read only the key name; `/proc/<pid>/cmdline`, shell history and agent transcripts are all readable — LAW-56a exists because a subagent leaked a prod DB password into a 0644 delegation log.
- **`raw` in secrets.yaml is an int flag, not a value.** A scan that flags "raw" as a hardcoded secret is a false positive.
- **A gate that times out is an unmeasured channel, not a PASS or a "broken tool".** Report it explicitly.
- **`grep -c` on an empty match returns 1 in some shells** (no newline) — use `wc -l` on the piped output for counts.
