#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/security-pro.sh — GATE-044 SECRETS-PRO
# Profesjonalny secret scan (gitleaks) — zamiennik heurystyki grep
# z GATE-005. Wykrywa sekrety wg reguł .gitleaks.toml (SEC-BASELINE):
# AWS/GCP/Azure, OpenAI/Anthropic/DeepSeek, GitHub/GitLab, Slack,
# Stripe, Twilio, JWT, private keys, connection strings.
#
# Zasada fail-closed: gitleaks ZAINSTALOWANY = uruchamiany; znaleziony
# sekret = BLOCKING FAIL z lokalizacją. Brak gitleaks = WARN (best-effort,
# GATE-005 grep-heurystyka dalej działa jako safety net).
#
# Użycie (source'owany przez verify.sh):
#   bash tools/verify/gates/domains/security-pro.sh
#   bash tools/verify/gates/domains/security-pro.sh --all   # skan historii git
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-044 SECRETS-PRO (gitleaks) ==="

SCAN_MODE="${1:-}"

# ── SECRETS-PRO-001: gitleaks dostępny ──────────────────────
if ! command -v gitleaks >/dev/null 2>&1; then
  warn "SECRETS-PRO-001 gitleaks dostępny" "gitleaks nie jest zainstalowany — GATE-005 (grep) jako safety net"
  verify_module_exit
fi
pass "SECRETS-PRO-001 gitleaks dostępny" BLOCKING "gitleaks: $(gitleaks version 2>/dev/null | head -1)"

# ── SECRETS-PRO-002: skan staged/range ──────────────────────
GITLEAKS_CONFIG=".gitleaks.toml"
GITLEAKS_ARGS=(detect --source "$ROOT" --config "$GITLEAKS_CONFIG" --no-banner --redact)

if [ "$SCAN_MODE" = "--all" ]; then
  GITLEAKS_ARGS+=(--log-opts="--all")
fi

if ! gitleaks "${GITLEAKS_ARGS[@]}" >/tmp/gitleaks-out.$$ 2>&1; then
  # gitleaks 8.x raportuje "leaks found: N" na stderr (mała litera) — grep
  # case-sensitive 'Leak|Secret' dawał 0 przy realnych leakach (mylący FAIL).
  LEAKS=$(grep -oE 'leaks? found:? ?[0-9]+' /tmp/gitleaks-out.$$ 2>/dev/null | grep -oE '[0-9]+' | head -1)
  [ -z "$LEAKS" ] && LEAKS=$(grep -ciE 'leak|secret' /tmp/gitleaks-out.$$ 2>/dev/null || echo 0)
  fail "SECRETS-PRO-002 skan sekretów" BLOCKING "$LEAKS sekret(ów) wykrytych — popraw przed commitem/pushem:"
  grep -E 'Description|File:|Secret:|leaks found' /tmp/gitleaks-out.$$ | head -30
  rm -f /tmp/gitleaks-out.$$
  verify_module_exit
fi
pass "SECRETS-PRO-002 skan sekretów" BLOCKING "gitleaks: brak wykrytych sekretów"

rm -f /tmp/gitleaks-out.$$

# ── SECRETS-PRO-003: konfiguracja SEC-BASELINE obecna ───────
if [ -f "$GITLEAKS_CONFIG" ]; then
  pass "SECRETS-PRO-003 konfiguracja .gitleaks.toml" BLOCKING "SEC-BASELINE obecny ($(grep -c '^\[\[rules\]\]' "$GITLEAKS_CONFIG") reguł)"
else
  fail "SECRETS-PRO-003 konfiguracja .gitleaks.toml" BLOCKING "Brak .gitleaks.toml — SEC-BASELINE wymagany"
fi

verify_module_exit
