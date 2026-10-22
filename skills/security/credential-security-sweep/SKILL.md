---
name: credential-security-sweep
description: >-
  Full-spectrum credential audit and remediation — find ALL hardcoded
  secrets across .env, Rust code, nginx configs, crontab, shell profiles,
  and migrate to Vault. Covers P0-P2 findings with systematic fix process.
source: auto-skill
extracted_at: '2026-06-29T18:07:15.429Z'
---


# Credential Security Sweep — Full Remediation

Systematic audit of ALL credential locations across a multi-node mesh,
followed by prioritized remediation (P0→P2).

## Phase 1: Discovery — Find Every Credential

### 1a. Env files

```bash
grep -rn 'API_KEY\|API_SECRET\|TOKEN\|PASSWORD\|SECRET\|KEY=' \
  <workspace>/.env <workspace>/.env 2>/dev/null \
  | grep -v '^#' | grep -v 'example\|template\|minimal'
```

Also check per-node env dirs:
```bash
grep -rn 'API_KEY\|TOKEN\|PASSWORD' <workspace>/deployment/env-nodes/ 2>/dev/null
```

### 1b. Rust code — hardcoded fallbacks + reqwest::blocking

```bash
# Hardcoded secrets in production code (not tests)
grep -rn 'unwrap_or_else\|\.unwrap_or(' <workspace>/runtime/crates/ --include='*.rs' \
  | grep -E '"[A-Za-z0-9_\-]{10,}"' | grep -v 'test\|#\[test\]'

# reqwest::blocking in async context (LAW-12 violation, blocks tokio)
grep -rn 'reqwest::blocking::Client::new\|reqwest::blocking::get' \
  <workspace>/runtime/crates/ --include='*.rs' | grep -v 'test\|#\[test\]'
```

### 1c. Nginx configs

```bash
grep -rn 'proxy_set_header.*X-API-Key\|proxy_set_header.*Authorization' \
  /etc/nginx/sites-enabled/ 2>/dev/null
```

### 1d. Crontab

```bash
crontab -l 2>/dev/null | grep -i 'token\|api_key\|password\|secret'
grep -rn 'VAULT_TOKEN\|API_KEY\|TOKEN=' /etc/cron.d/ 2>/dev/null
```

### 1e. Shell profiles

```bash
grep -n 'API_KEY\|TOKEN\|PASSWORD\|SECRET' ~/.bashrc ~/.bash_profile 2>/dev/null
```

### 1f. MCP Gateway config

```bash
cat <workspace>/config/mcp-servers.json | python3 -c "
import sys,json; d=json.load(sys.stdin)
for s in (d if isinstance(d,list) else [d]):
    print(f'{s.get(\"id\",\"?\")}: api_key={s.get(\"api_key\",\"(brak)\")[:30]}')
"
```

### 1g. Vault current state

```bash
TOKEN=$(python3 -c "import json; print(json.load(open('<workspace>/config/vault/secrets/vault-init.json'))['root_token'])")
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=$TOKEN \
  aigon-x-vault vault kv list -format=json secret/tenants/szamani/ 2>/dev/null
```

## Phase 2: Classify by Severity

| Priority | Criteria |
|----------|----------|
| **P0** | Credential in production code that executes when env var is missing |
| **P0** | Vault root token in plaintext accessible by unprivileged users |
| **P1** | Shared credential across multiple nodes/services (single breach = total) |
| **P1** | Default passwords (admin:<PASSWORD>) |
| **P2** | Credentials in shell profiles, readable by any process |
| **P2** | reqwest::blocking in async context (blocks executor) |

## Phase 3: Remediation

### P0 — Remove hardcoded fallbacks from code

For Rust code with `unwrap_or_else(|_| "HARDCODED_TOKEN".to_string())`:

1. Change `cf_token()` to return `Result<String, String>` (fail-closed)
2. Replace direct `reqwest::blocking::get(url)` with helper that injects Bearer token:
   ```rust
   fn cf_get(path: &str) -> Result<Value, String> {
       let token = cf_token()?;
       let url = format!("{API_BASE}{path}");
       let client = crate::blocking_http_client();
       let resp = client.get(&url)
           .header("Authorization", format!("Bearer {token}"))
           .send().map_err(|e| format!("API error: {e}"))?;
       resp.json::<Value>().map_err(|e| format!("Parse error: {e}"))
   }
   ```
3. Update all handlers to use the new helper, propagating errors as HTTP 502

### P0 — Remove VAULT_TOKEN from crontab

1. Backup: `crontab -l > /tmp/crontab-backup-$(date +%Y%m%d)`
2. Replace hardcoded token with script that reads from vault-init.json:
   ```bash
   #!/bin/bash
   VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('<workspace>/config/vault/secrets/vault-init.json'))['root_token'])")
   export VAULT_TOKEN
   exec python3 /path/to/original/script.py
   ```
3. Update crontab to call the wrapper script

### P1 — Centralize nginx API keys

1. Find all hardcoded keys: `grep -rn 'X-API-Key' /etc/nginx/sites-enabled/`
2. For each unique key, add a `map` block in `/etc/nginx/nginx.conf`:
   ```nginx
   map "" $aigon_api_key {
       default "ACTUAL_KEY_VALUE_HERE";
   }
   ```
3. Replace each `proxy_set_header X-API-Key "KEY";` with `proxy_set_header X-API-Key $aigon_api_key;`
4. Verify: `nginx -t && nginx -s reload`

### P1 — Change default passwords

```bash
# Grafana
kubectl exec -it deployment/grafana -- admin-password-reset NEWPASSWORD
# Or change in .env + restart
```

### P2 — Clean shell profiles

1. Backup: `cp ~/.bashrc ~/.bashrc.backup-$(date +%Y%m%d)`
2. Comment out all lines with `API_KEY`, `TOKEN`, `PASSWORD`, `SECRET`
3. Leave non-secret configuration vars (model names, endpoints without auth)

### P2 — Migrate credentials to Vault

For each credential from `.env`, write to Vault:

```bash
VAULT="docker exec -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN=$(cat <workspace>/config/vault/secrets/vault-init.json | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"root_token\"])') \
  aigon-x-vault vault"

$VAULT kv put secret/tenants/szamani/surrealdb/password value="$(grep SURREAL_PASSWORD <workspace>/.env | cut -d= -f2)"
```

Verify: `$VAULT kv list secret/tenants/szamani/`

## Phase 4: Verify

```bash
# 1. No compilation errors
cargo check -p aigon-runtime 2>&1 | grep '^error' | wc -l  # must be 0

# 2. No credentials in crontab
grep -c 'VAULT_TOKEN\|API_KEY' /etc/cron.d/* 2>/dev/null || echo "0"

# 3. No credentials in .bashrc
grep -c 'API_KEY\|TOKEN=\|PASSWORD' ~/.bashrc | grep -v '^#' || echo "0"

# 4. Vault has all migrated secrets
$VAULT kv list secret/tenants/szamani/

# 5. Cloudflare API calls fail closed without env var
unset CLOUDFLARE_API_TOKEN
curl -s localhost:14500/api/cloudflare/zones | grep -c 'not set'  # must be 1
```
