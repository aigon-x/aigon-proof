#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/test_project_visual_verification_negative.sh — TEST
#  NEGATYWNY dla gate'a project-visual-verification (LAW-VERIFY-1).
#
#  KANON REPO: „test negatywny obowiązkowy — bramka bez testu negatywnego
#  nie istnieje". Ten test WSTRZYKUJE raport weryfikacji projektu, którego
#  JEDYNYM dowodem jest curl/status HTTP (bez screenshota) i sprawdza, że
#  bramka go ZŁAPIE (exit 1 = FAIL). Kontrola: raport ze screenshotem NIE
#  może dać FAIL (fałszywy pozytyw).
#
#  BEZ SIECI, BEZ CARGO, BEZ DOCKERA — wyłącznie fixture pliki.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project-visual-verification.sh"
[ -f "$GATE" ] || { echo "brak gate: $GATE"; exit 2; }

TMP="$(mktemp -d /tmp/project-visual-neg.XXXXXX)"
PASS=0; FAILED=0
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Fixture A: curl-only (false-green) — bramka MUSI to złapać ──────────
mkdir -p "$TMP/curl_only"
cat > "$TMP/curl_only/report.ndjson" << 'EOF'
{"ts":"2026-10-06T00:00:00","text":"Weryfikacja projektu: domena https://demo.szamani.ai — sprawdzono, wszystko ok. curl -o /dev/null -w '%{http_code}' zwraca 200. Projekt działa."}
EOF

# ── Fixture B: visual (poprawny) — bramka NIE może dać FAIL ─────────────
mkdir -p "$TMP/visual"
cat > "$TMP/visual/report.ndjson" << 'EOF'
{"ts":"2026-10-06T00:00:00","text":"Weryfikacja projektu: domena https://demo.szamani.ai — agent-browser open, screenshot zapisany, render poprawny, przeklikano ścieżkę. Projekt działa."}
EOF

# ── CASE 1: curl-only → exit 1 (FAIL) ────────────────────────────────────
OUT_A=$(AIGON_PROJECT_VERIFY_EVIDENCE="$TMP/curl_only" bash "$GATE" 2>&1); RC_A=$?
if [ "$RC_A" = "1" ]; then
  echo "PASS: 1. bramka ZŁAPAŁA curl-only (exit=$RC_A)"
  PASS=$((PASS+1))
else
  echo "FAIL: 1. curl-only nie dało exit=1 (jest exit=$RC_A)"
  printf '%s\n' "$OUT_A" | tail -6
  FAILED=$((FAILED+1))
fi

# ── CASE 2: visual → NIE exit 1 (PASS 0 lub WARN 2, byle nie FAIL) ──────
OUT_B=$(AIGON_PROJECT_VERIFY_EVIDENCE="$TMP/visual" bash "$GATE" 2>&1); RC_B=$?
if [ "$RC_B" != "1" ]; then
  echo "PASS: 2. raport ze screenshotem nie dał FAIL (exit=$RC_B)"
  PASS=$((PASS+1))
else
  echo "FAIL: 2. raport visual dostał FAIL (exit=$RC_B) — fałszywy pozytyw"
  printf '%s\n' "$OUT_B" | tail -6
  FAILED=$((FAILED+1))
fi

# ── CASE 3: brak raportów → exit 2 (WARN), nie FAIL ──────────────────────
mkdir -p "$TMP/empty"
OUT_C=$(AIGON_PROJECT_VERIFY_EVIDENCE="$TMP/empty" bash "$GATE" 2>&1); RC_C=$?
if [ "$RC_C" = "2" ]; then
  echo "PASS: 3. brak raportów → exit 2 (WARN, nie FAIL)"
  PASS=$((PASS+1))
else
  echo "FAIL: 3. brak raportów — chciano exit=2, jest exit=$RC_C"
  FAILED=$((FAILED+1))
fi

# ── Podsumowanie ───────────────────────────────────────────────────────
echo "────────────────────────────────────────────"
echo "WYNIK: $PASS pass, $FAILED fail"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
