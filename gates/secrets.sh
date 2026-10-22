#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# security/secrets.sh — Universal Project Template — Repository Certification Engine
# Moduł: SECURITY — SECRETS
# Wykrywa sekrety w working tree i staged diff.
# Deleguje do istniejącego tools/security/secret-scan.sh (gitleaks).
#
# Checki:
#   SEC-001  No secrets in working tree (delegated to secret-scan.sh)
#   SEC-002  No secrets in staged diff
#   SEC-003  No .env files (poza .env.example)
#   SEC-004  No private key files
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== SECURITY — SECRETS ==="

# SEC-001 No secrets in working tree (delegated to secret-scan.sh)
if bash tools/security/secret-scan.sh >/dev/null 2>&1; then
  pass "SEC-001 No secrets in working tree" "secret-scan.sh (gitleaks) — brak sekretów."
else
  fail "SEC-001 No secrets in working tree" BLOCKING "secret-scan.sh wykrył sekrety."
fi

# SEC-002 No secrets in staged diff
# Skanujemy tylko pliki, które mają trafić do commita.
STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
if [ -n "$STAGED" ]; then
  # Wzorce sekretów w staged plikach
  if echo "$STAGED" | grep -qE '\.(pem|key|p12|pfx|jks)$'; then
    fail "SEC-002 No secrets in staged diff" BLOCKING "Plik klucza/certyfikatu w staged: $STAGED"
  elif echo "$STAGED" | grep -qE '(^|/)\.env$'; then
    fail "SEC-002 No secrets in staged diff" BLOCKING "Plik .env w staged (sekrety!)."
  else
    pass "SEC-002 No secrets in staged diff"
  fi
else
  pass "SEC-002 No secrets in staged diff" "Brak staged plików."
fi

# SEC-003 No .env files (poza .env.example)
# Skanujemy tylko git-tracked pliki (repo_files) — nieśledzone artefakty
# robocze (np. .qwen/) nie są częścią repo i nie wchodzą do commita.
ENV_FILES=$(repo_files --name '(^|/)\.env$' | grep -v '\.env\.example$')
if [ -n "$ENV_FILES" ]; then
  fail "SEC-003 No .env files" BLOCKING "Pliki .env w repo: $ENV_FILES"
else
  pass "SEC-003 No .env files"
fi

# SEC-004 No private key files
KEY_FILES=$(repo_files --name '\.(pem|key|p12|pfx|jks)$')
if [ -n "$KEY_FILES" ]; then
  fail "SEC-004 No private key files" BLOCKING "Pliki kluczy: $KEY_FILES"
else
  pass "SEC-004 No private key files"
fi

verify_module_exit
