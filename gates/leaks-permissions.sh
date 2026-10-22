#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/leaks-permissions.sh — GATE-133 LEAKS-PERMISSIONS
#
# Powstalo 2026-09-25 po ZMIERZONYM wycieku uprawnien w runtime/leaks:
# cztery katalogi niosace PII (dossier = 12 plikow, a NAZWY plikow SAME
# sa PII) mialy bity swiata — kazdy uzytkownik hosta mogl je wylistowac
# i odczytac. GATE-132 (FILE-PERMISSIONS) mierzy scripts/config/tools,
# a runtime/leaks lezy POZA jego zakresem — dlatego regresja wrocilaby
# po cichu, bez zadnego detektora. Ta bramka domyka ten zakres.
#
# ZASADA POMIARU (bez stalych):
#   - liczby NIE sa wpisane w bramce; pochodza z `stat -c '%a'` na ZYWYCH
#     sciezkach: runtime/leaks{,/dossier,/stale,/quarantine} + pliki w srodku
#     (lista z `rg --files --no-ignore --hidden`; LAW-TOOL-1: ZERO `find`);
#   - naruszenie BLOCKING = bity swiata (ostatnia cyfra trybu) != 0;
#   - naruszenie BLOCKING = sciezka istnieje, ale nie da sie jej zmierzyc
#     (fail-closed: niemierzalne != zielone);
#   - WARNING = katalog bez setgid (dryf od kanonu 2770 aigon:aigon);
#   - brak runtime/leaks = INFO + PASS wprost (vacuous) — katalog jest stanem
#     runtime poza gitem, jego brak nie jest defektem, a bramka NIE udaje
#     wtedy pomiaru.
# ─────────────────────────────────────────────────────────────
set -u
# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

GATE_ID="GATE-133 LEAKS-PERMISSIONS"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

LEAKS="runtime/leaks"
DIRS=("$LEAKS" "$LEAKS/dossier" "$LEAKS/stale" "$LEAKS/quarantine")

if [ ! -d "$LEAKS" ]; then
  info "$GATE_ID: brak $LEAKS — nic do wycieku" "sciezka nie istnieje (stan runtime poza git)"
  pass "$GATE_ID calosc" BLOCKING "katalog nieobecny; warunek spelniony wprost (vacuous), nie zmierzony"
  evidence_record "verify:leaks-permissions:ABSENT" "verify" "leaks-permissions.sh"
  verify_module_exit
fi

# ── Zbieranie sciezek (BEZ `find` — LAW-TOOL-1) ──────────────
PATHS=()
DIRS_PRESENT=0
for d in "${DIRS[@]}"; do
  if [ -d "$d" ]; then PATHS+=("$d"); DIRS_PRESENT=$((DIRS_PRESENT+1)); fi
done

FILES=()
if command -v rg >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$f")
  done < <(rg --files --no-ignore --hidden "$LEAKS" 2>/dev/null || true)
else
  shopt -s globstar nullglob
  for f in "$LEAKS"/**/*; do
    [ -f "$f" ] && FILES+=("$f")
  done
fi
[ "${#FILES[@]}" -gt 0 ] && PATHS+=("${FILES[@]}")

# ── Pomiar (arytmetyka osemkowa — tryb to NIE string) ────────
VIOL=()
NOGID=()
UNREAD=0
TOTAL=0
for p in "${PATHS[@]}"; do
  if ! MODE=$(stat -c '%a' "$p" 2>/dev/null); then
    UNREAD=$((UNREAD+1))
    continue
  fi
  TOTAL=$((TOTAL+1))
  M=$(( 8#$MODE ))
  if [ "$(( M & 0007 ))" -ne 0 ]; then
    VIOL+=("$(stat -c '%A %a %U:%G %n' "$p" 2>/dev/null || printf '%s %s' "$MODE" "$p")")
  fi
  if [ -d "$p" ] && [ "$(( M & 02000 ))" -eq 0 ]; then
    NOGID+=("$(stat -c '%a %U:%G %n' "$p" 2>/dev/null || printf '%s %s' "$MODE" "$p")")
  fi
done

say ""
say "$GATE_ID — pomiar: $TOTAL sciezek ($DIRS_PRESENT katalogow + ${#FILES[@]} plikow) w $LEAKS"

if [ "$UNREAD" -gt 0 ]; then
  fail "$GATE_ID: $UNREAD sciezek niemierzalnych w $LEAKS" BLOCKING \
    "fail-closed: nie da sie potwierdzic braku bitow swiata — traktowane jak naruszenie"
  evidence_record "verify:leaks-permissions:FAIL" "verify" "leaks-permissions.sh"
  verify_module_exit
fi

if [ "${#VIOL[@]}" -gt 0 ]; then
  say "  [NARUSZENIE] sciezki z bitami swiata (world r/w/x):"
  for v in "${VIOL[@]}"; do say "    $v"; done
  say "  [NAPRAWA] sudo -n chmod o-rwx <sciezka>   # kanon: katalogi 2770 aigon:aigon, pliki 640"
  fail "$GATE_ID: ${#VIOL[@]} sciezek world-* w $LEAKS" BLOCKING \
    "bity swiata != 0000 — PII (nazwy plikow tez) dosiegalne dla kazdego uzytkownika hosta"
  evidence_record "verify:leaks-permissions:FAIL" "verify" "leaks-permissions.sh"
  verify_module_exit
fi

if [ "${#NOGID[@]}" -gt 0 ]; then
  warn "$GATE_ID: ${#NOGID[@]} katalogow bez setgid (dryf od kanonu 2770)" \
    "$(printf '%s; ' "${NOGID[@]}")"
fi

pass "$GATE_ID calosc" BLOCKING \
  "0 sciezek z bitami swiata na $TOTAL zmierzonych (katalogi + pliki w $LEAKS)"
evidence_record "verify:leaks-permissions:PASS" "verify" "leaks-permissions.sh"
verify_module_exit
