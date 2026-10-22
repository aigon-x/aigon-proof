#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# security/sec-rotation-check.sh — Universal Project Template — Repository Certification Engine
# Moduł: SEC-BASELINE — CREDENTIAL ROTATION
# Weryfikuje, że poświadczenia są rotowane: data_rotacji nie jest przeterminowana
# (poza dozwolonym oknem) i przeterminowane poświadczenia są oznaczone jako
# wymagające rotacji (status "rotating").
#
# SEC-BASELINE: ten moduł rodzi się w KAŻDYM projekcie utworzonym z template'u.
# ZASADA TEMPLATE: skrypt MUSI przechodzić na świeżym projekcie. Placeholdery
# w config/canonical/credentials.yaml NIE są realnymi sekretami.
#
# Checki:
#   SEC-ROT-01  Every credential has a rotation date in the future or within the allowed window
#   SEC-ROT-02  Expired credentials are marked as requiring rotation (status "rotating")
#
# Delegacja: czyta config/canonical/credentials.yaml (YAML). Parsowanie przez
# awk (fallback, bez zależności od yq). Okno rotacji: 90 dni (konfigurowalne
# przez ROTATION_WINDOW_DAYS).
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== SEC-BASELINE — CREDENTIAL ROTATION (SEC-ROT-01..02) ==="

REGISTRY="$ROOT/config/canonical/credentials.yaml"
ROTATION_WINDOW_DAYS="${ROTATION_WINDOW_DAYS:-90}"

# ── SEC-ROT-01 wymaga rejestru ──────────────────────────────
if [ ! -f "$REGISTRY" ]; then
  fail "SEC-ROT-01 Rotation dates in future/window" BLOCKING "Brak rejestru poświadczeń: $REGISTRY"
  fail "SEC-ROT-02 Expired marked as rotating" BLOCKING "Brak rejestru poświadczeń: $REGISTRY"
  evidence_record "verify:sec-rotation-check:FAIL" "verify" "security/sec-rotation-check.sh"
  verify_module_exit
fi

# ── Parsowanie wpisów (name|rotation_date|status) ───────────
# Usuwamy cudzysłowy z wartości dat (YAML: rotation_date: "2026-12-01").
parse_entries() {
  awk '
    /^  - name:/ {
      if (name != "") print name "|" rot "|" status
      name=$3; rot=""; status=""
      next
    }
    /^    rotation_date:/ { rot=$2; gsub(/"/, "", rot); next }
    /^    status:/ { status=$2; next }
    END { if (name != "") print name "|" rot "|" status }
  ' "$REGISTRY"
}

ENTRIES="$(parse_entries)"
if [ -z "$ENTRIES" ]; then
  fail "SEC-ROT-01 Rotation dates in future/window" BLOCKING "Rejestr nie zawiera żadnych wpisów."
  fail "SEC-ROT-02 Expired marked as rotating" BLOCKING "Rejestr nie zawiera żadnych wpisów."
  evidence_record "verify:sec-rotation-check:FAIL" "verify" "security/sec-rotation-check.sh"
  verify_module_exit
fi

# ── Obliczanie progu okna rotacji ───────────────────────────
# data_rotacji musi być >= (dzisiaj - okno). Używamy date -d (GNU date).
# Jeśli date -d niedostępny (BSD/macOS), fallback: porównanie dat jako stringów
# (ISO-8601 sortuje leksykograficznie) — mniej precyzyjne, ale deterministyczne.
TODAY="$(date +%Y-%m-%d)"
CUTOFF=""
if date -d "$TODAY - $ROTATION_WINDOW_DAYS days" >/dev/null 2>&1; then
  CUTOFF="$(date -d "$TODAY - $ROTATION_WINDOW_DAYS days" +%Y-%m-%d)"
fi

# ── SEC-ROT-01 Rotation dates in future/window ──────────────
# Wpis jest OK, jeśli data_rotacji >= cutoff (w przyszłości lub w oknie).
# Wpisy "revoked" są wyłączone z wymogu rotacji (nieużywane).
EXPIRED=""
if [ -n "$CUTOFF" ]; then
  # GNU date dostępny — porównanie dat.
  while IFS='|' read -r name rot status; do
    [ -z "$name" ] && continue
    [ "$status" = "revoked" ] && continue
    if [ -z "$rot" ]; then
      EXPIRED="$EXPIRED $name(no-date)"
      continue
    fi
    if [ "$rot" \< "$CUTOFF" ]; then
      EXPIRED="$EXPIRED $name($rot)"
    fi
  done <<< "$ENTRIES"
else
  # Fallback: porównanie leksykograficzne ISO-8601 (dzisiaj - okno przybliżone).
  # Używamy daty sprzed okna dni (przybliżenie kalendarzowe).
  CUTOFF_LEX="$(date -d "$TODAY - $ROTATION_WINDOW_DAYS days" +%Y-%m-%d 2>/dev/null || echo "$TODAY")"
  while IFS='|' read -r name rot status; do
    [ -z "$name" ] && continue
    [ "$status" = "revoked" ] && continue
    if [ -z "$rot" ] || [ "$rot" \< "$CUTOFF_LEX" ]; then
      EXPIRED="$EXPIRED $name($rot)"
    fi
  done <<< "$ENTRIES"
fi

if [ -z "$EXPIRED" ]; then
  pass "SEC-ROT-01 Rotation dates in future/window" BLOCKING "Wszystkie aktywne poświadczenia mają datę rotacji w przyszłości lub w oknie $ROTATION_WINDOW_DAYS dni."
else
  fail "SEC-ROT-01 Rotation dates in future/window" BLOCKING "Przeterminowane daty rotacji:$(printf '%s' "$EXPIRED")"
fi

# ── SEC-ROT-02 Expired marked as requiring rotation ─────────
# Każde przeterminowane poświadczenie (poza oknem) MUSI mieć status "rotating".
# Wpisy "revoked" są wyłączone (nie wymagają rotacji).
NOT_ROTATING=""
while IFS='|' read -r name rot status; do
  [ -z "$name" ] && continue
  [ "$status" = "revoked" ] && continue
  # Czy wpis jest przeterminowany?
  is_expired=0
  if [ -n "$CUTOFF" ]; then
    if [ -n "$rot" ] && [ "$rot" \< "$CUTOFF" ]; then is_expired=1; fi
  else
    if [ -n "$rot" ] && [ "$rot" \< "$CUTOFF_LEX" ]; then is_expired=1; fi
  fi
  if [ "$is_expired" -eq 1 ] && [ "$status" != "rotating" ]; then
    NOT_ROTATING="$NOT_ROTATING $name($status)"
  fi
done <<< "$ENTRIES"

if [ -z "$NOT_ROTATING" ]; then
  pass "SEC-ROT-02 Expired marked as rotating" BLOCKING "Wszystkie przeterminowane poświadczenia są oznaczone jako wymagające rotacji (status rotating)."
else
  fail "SEC-ROT-02 Expired marked as rotating" BLOCKING "Przeterminowane poświadczenia bez statusu rotating:$(printf '%s' "$NOT_ROTATING")"
fi

# ── Evidence ─────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:sec-rotation-check:FAIL" "verify" "security/sec-rotation-check.sh"
else
  evidence_record "verify:sec-rotation-check:PASS" "verify" "security/sec-rotation-check.sh"
fi

verify_module_exit
