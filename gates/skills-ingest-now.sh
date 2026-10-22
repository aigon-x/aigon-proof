#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/skills-ingest-now.sh — natychmiastowy ingest skilli do rejestru
#
#  PO CO (luka potwierdzona 2026-09-24):
#    skills-ingest mial WYLACZNIE cron */15. Skill zapisany w SSOT
#    lezal bezuzyteczny do 15 minut — albo na zawsze, gdy nikt nie czekal.
#    Zmierzone: skill zlozony 03:34, ingest zlapal dopiero po RECZNYM
#    uruchomieniu o 03:36 (Diff: zapisane 1, wierszy 2417).
#    To jest wlasnie ta luka, ktora Suweren wskazal: "to mialo byc hookiem
#    robione — pojawi sie skill po normalizacji i leci ingest".
#
#  Ten gate jest wywolywany przez hook-runner.sh z triggera `skills:ingest`,
#  ale dziala TEZ standalone (idempotentny — ingest sam liczy diff).
#
#  Kontrakt bramki: 0 = PASS, 1 = FAIL, 2 = WARN
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/srv/aigon}"
INGEST="${ROOT}/scripts/skills-ingest-cron.sh"
SSOT_DIR="${ROOT}/skills/shared"

[ -x "$INGEST" ] || { echo "FAIL: brak wykonywalnego $INGEST"; exit 1; }
[ -d "$SSOT_DIR" ] || { echo "FAIL: brak katalogu SSOT $SSOT_DIR"; exit 1; }

# ── Bramka wejscia: skill MUSI miec niepusty SKILL.md (w sobie ALBO w podkatalogu) ──
# PITFALL (2026-09-24): /srv/aigon/skills/shared/<x> bywa KOLEKCJA (np. anthropic-skills,
# superpowers) — SKILL.md zyje w podkatalogach, nie na szczycie. Bramka sprawdzajaca
# tylko <x>/SKILL.md dawala FALSZYWY FAIL na 2 z 2390. Sprawdzamy tez glebiej.
BROKEN=0; N=0; COLLECTIONS=0
while IFS= read -r d; do
  N=$((N+1))
  if [ -s "$d/SKILL.md" ]; then
    continue
  fi
  # Kolekcja? Ma choc jeden podkatalog z niepustym SKILL.md.
  if find "$d" -mindepth 2 -maxdepth 3 -name SKILL.md -size +0c -print -quit 2>/dev/null | grep -q .; then
    COLLECTIONS=$((COLLECTIONS+1))
    continue
  fi
  echo "  PUSTY/BRAK: $d"
  BROKEN=$((BROKEN+1))
done < <(find "$SSOT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

if [ "$BROKEN" -gt 0 ]; then
  echo "FAIL: $BROKEN z $N wpisow w SSOT bez niepustego SKILL.md (ingest ich NIE zobaczy)"
  exit 1
fi

# ── Ingest: uruchom i wyciagnij diff ────────────────────────────────────
# PITFALL (2026-09-24): ingest konczy sie LOGIEM PROMOCJI, nie linia `Diff:`.
# Gate czytajacy ostatnia linie dawal FALSZYWY FAIL na sukcesie
# ("Promocja: 0 skilli" = poprawny wynik dedup md5, nie porazka).
# Dowodem sukcesu jest LINIA `Diff:` + rc=0, szukana gdziekolwiek w outputcie.
OUT="$(cd "$ROOT" && timeout 300 ./scripts/skills-ingest-cron.sh 2>&1)"
RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: ingest rc=$RC"; echo "$OUT" | tail -5; exit 1; }

DIFF_LINE="$(echo "$OUT" | grep -E '^Diff: ' | tail -1)"
TOTAL_LINE="$(echo "$OUT" | grep -E 'wierszy w tabeli skills' | tail -1)"
PROMO_LINE="$(echo "$OUT" | grep -E '^Promocja: ' | tail -1)"

# Brak linii Diff = ingest nie dotarl do zapisu (Vault/PG) — to FAIL, nie cichy PASS.
if [ -z "$DIFF_LINE" ]; then
  echo "FAIL: ingest nie zwrocil linii 'Diff:' — brak zapisu (Vault/PG?)"
  echo "$OUT" | tail -5
  exit 1
fi

echo "OK: skilli w SSOT=$N | $DIFF_LINE | ${TOTAL_LINE:-brak licznika} | ${PROMO_LINE:-brak promocji}"
exit 0
