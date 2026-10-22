#!/usr/bin/env bash
# ============================================================================
# safety-limits-check.sh — SAFETY-LIMITS GATE (GATE-119)   [qg G298]
# ============================================================================
# limity wykonawcze/blokady/awaryjne zatrzymanie dzialaja. Fail-closed: brak
# dowodu = BLOCKING FAIL, nigdy skip.
# Unified gate: JEDEN skrypt widoczny jako gate (registry) I jako modul verify
# (gates.yaml) — pipeline CI i lokalna pelna certyfikacja egzekwuja TO SAMO.
#
# PRZEPIECIE 2026-09-24 (rozkaz Suwerena: „przepiac z fasady na realna"):
# Poprzednia wersja sprawdzala WYLACZNIE, czy string „G298" wystepuje w pliku
# evidence. Nie dotykala ani jednego realnego limitu — byla deklaracja, nie
# weryfikacja (klasa „fasada": zielona, a nie pilnuje niczego).
# Teraz bramka sprawdza TRZY realne warunki:
#   [1] SSOT blokad wykonawczych (runtime/manifests/policies.yaml) istnieje,
#       parsuje sie i ma >=1 regule deny|limit — blokady sa ZDEFINIOWANE.
#   [2] Runtime ZYJE i egzekwuje je: GET /runtime/policies zwraca te reguly
#       (dowod, ze blokady dzialaja, a nie tylko leza w pliku).
#   [3] Limity serwisow == SSOT (scripts/limits-render.py --verify) — limity
#       wykonawcze stacku (restart/healthcheck/progi watchdogow).
# Kazdy brak = FAIL (fail-closed). Runtime niedostepny = FAIL, bo wtedy
# blokady NIE dzialaja — a to jest dokladnie to, co bramka ma lapac.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-119 SAFETY-LIMITS (SAFETY) ==="

FAILED=0

# ── [1] SSOT blokad wykonawczych zdefiniowany ────────────────────────────
POLICIES="runtime/manifests/policies.yaml"
if [ ! -s "$POLICIES" ]; then
  fail "GATE-119 SSOT blokad" BLOCKING "Brak $POLICIES (blokady wykonawcze niezdefiniowane)."
  FAILED=1
else
  RULES=$(python3 - "$POLICIES" <<'PY' 2>/dev/null
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(2)
n = 0
for e in (d.get("entries") or []):
    a = str((e or {}).get("action", ""))
    if a.startswith("deny") or a.startswith("limit"):
        n += 1
print(n)
PY
)
  if [ "${RULES:-0}" -ge 1 ] 2>/dev/null; then
    say "  [1] $POLICIES: ${RULES} regul deny|limit (blokady zdefiniowane)"
  else
    fail "GATE-119 SSOT blokad" BLOCKING "$POLICIES bez regul deny|limit (lub nieparsowalny)."
    FAILED=1
  fi
fi

# ── [2] Runtime egzekwuje blokady (dowod z zywego API) ───────────────────
# KOREKTA 2026-10-19 (zmierzone): runtime :7000 autoryzuje klucz AIGON_API_KEY
# (64 znaki, ten sam co w env_file kontenera). Bramka brala WYLACZNIE legacy
# nazwy (AIGON_RUNTIME_SHARED_SECRET / RUNTIME_SHARED_SECRET, 43 znaki) →
# dostawala 401, traktowala to jako „runtime nie potwierdzil regul" i dawala
# FAIL na LAW-53, mimo ze endpoint zwraca 6 regul. To ta sama klasa co
# hook-runner evidence 401: autorytet = klucz, ktory sprawdza runtime.
# AUTORYTET KLUCZA = env_file runtime'u (core/.env), nie shell agenta.
# Zmierzone 2026-10-19: shell AIGON_API_KEY (64 znaki) -> 401; core/.env
# AIGON_API_KEY (43 znaki) -> /runtime/policies count=5. Shell env bywa stary,
# a bramka ma mierzyć FAKT (klucz procesu), nie kopię w środowisku wywołującego.
API_KEY=""
if [ -f core/.env ]; then
  API_KEY=$(grep -m1 -E '^AIGON_API_KEY=' core/.env 2>/dev/null | cut -d= -f2- | tr -d '"')
fi
if [ -z "$API_KEY" ]; then
  API_KEY="${AIGON_API_KEY:-${AIGON_RUNTIME_SHARED_SECRET:-${AIGON_RUNTIME_API_KEY:-${RUNTIME_API_KEY:-}}}}"
fi
if [ -z "$API_KEY" ] && [ -f core/.env ]; then
  API_KEY=$(grep -m1 -E '^(AIGON_RUNTIME_SHARED_SECRET|RUNTIME_SHARED_SECRET)=' core/.env 2>/dev/null | cut -d= -f2-)
fi
LIVE=""
RUNTIME_URL="${AIGON_SAFETY_RUNTIME_URL:-https://127.0.0.1:7000}"
LIMITS_RENDERER="${AIGON_SAFETY_LIMITS_RENDERER:-scripts/limits-render.py}"
# Every deny/limit rule from SSOT must be loaded unchanged. A positive count
# alone, HTTP failure, malformed JSON, or unrelated inventory is not evidence.
live_policy_count() {
  python3 -c '
import sys, json, yaml, re
try:
    live = json.load(sys.stdin)
    entries = (yaml.safe_load(open(sys.argv[1])) or {}).get("entries", [])
    expected = [e for e in entries if isinstance(e, dict) and str(e.get("action", "")).startswith(("deny", "limit"))]
    rules = live.get("rules")
    if not isinstance(rules, list) or type(live.get("count")) is not int or live["count"] != len(rules) or not expected:
        raise ValueError("invalid policy inventory")
    fields = ("name", "resource", "condition", "action")
    def valid(rule):
        return (isinstance(rule, dict) and
                all(isinstance(rule.get(k), str) and rule[k].strip() for k in fields) and
                (rule["action"] == "deny" or re.fullmatch(r"limit=\d+", rule["action"]) is not None))
    if not all(valid(e) for e in expected):
        raise ValueError("invalid SSOT enforcement rule")
    if any(not any(isinstance(r, dict) and all(r.get(k) == e.get(k) for k in fields) for r in rules) for e in expected):
        raise ValueError("SSOT enforcement rules not loaded")
    print(len(expected))
except Exception:
    print(0)
' "$POLICIES"
}
if [ -n "$API_KEY" ]; then
  # REMEDIACJA 2026-10-03 (Hermes): endpoint /runtime/policies pod obciazeniem
  # odpowiada ~7 s (zmierzone: 7,0 s w 2 z 5 prob) — czyli DOKLADNIE na granicy
  # `curl -m 8`. Skutek: GATE-119 [2] migotal FAIL/PASS, a przez to fitness
  # LAW-53 (safety-limits) w constitution-fitness raz dawal exit 1 (zlamanie),
  # raz 0 — falszywy czerwien blokujacy pre-push calej flocie (zmierzone:
  # hook-runner pre-push 2026-10-03 20:51 FAIL na constitution-fitness mimo
  # ze /runtime/policies zyje). Retry 3x + timeout 20 s usuwa szum NIE zmieniajac
  # semantyki: reachable-ale-puste nadal = FAIL (fail-closed bez zmian).
  for _try in 1 2 3; do
    LIVE=$(curl -fsk -m 20 -H "X-API-Key: $API_KEY" "${RUNTIME_URL%/}/runtime/policies" 2>/dev/null) || LIVE=""
    LIVE_COUNT=$(printf '%s' "$LIVE" | live_policy_count 2>/dev/null)
    [ "${LIVE_COUNT:-0}" -ge 1 ] 2>/dev/null && break
    sleep 2
  done
fi
LIVE_COUNT=$(printf '%s' "$LIVE" | live_policy_count 2>/dev/null)
if [ "${LIVE_COUNT:-0}" -ge 1 ] 2>/dev/null; then
  say "  [2] runtime egzekwuje blokady: /runtime/policies -> count=${LIVE_COUNT}"
else
  fail "GATE-119 egzekwowanie" BLOCKING "Runtime nie potwierdzil regul (/runtime/policies puste/nieosiagalne) — blokady wykonawcze NIE dzialaja."
  FAILED=1
fi

# ── [3] Limity serwisu == SSOT ───────────────────────────────────────────
if [ -f "$LIMITS_RENDERER" ] && [ -f config/limits.yaml ]; then
  if OUT=$(AIGON_ROOT="$ROOT" python3 "$LIMITS_RENDERER" --verify 2>&1); then
    say "  [3] ${OUT}"
  else
    fail "GATE-119 limity serwisu" BLOCKING "Rozjazd limitow serwisu wobec config/limits.yaml: ${OUT%%$'\n'*}"
    FAILED=1
  fi
else
  fail "GATE-119 limity serwisu" BLOCKING "Brak SSOT limitow (config/limits.yaml) lub konsumenta (scripts/limits-render.py)."
  FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  evidence_record "verify:safety-limits:FAIL" "verify" "safety-limits-check.sh"
  verify_module_exit
fi

pass "GATE-119 SAFETY-LIMITS calosc" BLOCKING "Blokady wykonawcze zdefiniowane i egzekwowane; limity serwisu == SSOT."
evidence_record "verify:safety-limits:PASS" "verify" "safety-limits-check.sh"
verify_module_exit
