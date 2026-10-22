#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/skill-graph-freshness.sh — gate SKILL-GRAPH-FRESHNESS
#
#  PO CO (rozkaz Suwerena 2026-09-29: „graf musi się aktualizować dynamicznie
#  jakimś gate'em albo coś"):
#    `config/canonical/skill-graph.yaml` (graf wiedzy: kategorie + przypisanie
#    skilli) był GENEROWANY RĘCZNIE przez scripts/skill-graph-generate.py.
#    Zmierzone: deklarował `skill_files: 2501`, gdy SSOT miał 2791 — rozjazd
#    290 skilli, o których graf NIC nie wiedział. Nie było ani crona, ani bramy,
#    więc rozjazd rósł cicho przy każdej instalacji skilla.
#
#  CO MIERZY (dwie asercje):
#    1. ŚWIEŻOŚĆ: graf musi być nowszy niż najnowszy SKILL.md w SSOT. Jeśli
#       jakikolwiek skill został dodany/zmieniony PO wygenerowaniu grafu —
#       graf kłamie (nie zna tego skilla).
#    2. KOMPLETNOŚĆ: liczba skilli w grafie musi zgadzać się z liczbą plików
#       SKILL.md w SSOT (z tolerancją na świadome duplikaty nazw).
#
#  NAPRAWA: brama SAMA regeneruje graf (jest idempotentna i tania) i dopiero
#  potem mierzy. Dzięki temu działa jak gate samonaprawczy, a nie tylko alarm.
#  Regeneracja nie jest zmianą w repo — trzeba ją zacommitować (brama to zgłasza).
#
#  KONTRAKT: exit 0 = PASS, exit 1 = FAIL (graf nieaktualny).
#  Env: AIGON_SKILL_GRAPH_AUTOFIX=0 wyłącza samonaprawę (tryb read-only).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSOT="$ROOT/skills/shared"
GRAPH="$ROOT/config/canonical/skill-graph.yaml"
GEN="$ROOT/scripts/skill-graph-generate.py"
AUTOFIX="${AIGON_SKILL_GRAPH_AUTOFIX:-1}"
export PATH="/usr/bin:/usr/local/bin:$PATH"

fails=0
say() { printf '       %s\n' "$*"; }

for f in "$SSOT" "$GEN"; do
  if [ ! -e "$f" ]; then
    say "FAIL: brak $f"
    echo "skill-graph-freshness: FAIL (brak wejscia)"
    exit 1
  fi
done

# ── Najnowszy SKILL.md w SSOT (mtime) ───────────────────────────────────
# UWAGA (zmierzone 2026-10-17): gołe `find -name SKILL.md` liczyło też pliki
# z WNĘTRZA zależności skilli — `animation-magic-excellence/.venv-shot/lib/
# python3.11/site-packages/playwright/.../skills/*` (3 pliki). Skutek był
# podwójny: (a) n_skills=2881, gdy realnych skilli jest 2878, więc AUTOFIX
# NIGDY nie mógł spełnić `g2 >= n_skills` → bramka FAILowała na zdrowym
# systemie; (b) najnowszy mtime pochodził z venva → permanentny „graf stary".
# To ta sama klasa co liczenie `.archive` jako dostarczonego skilla.
find_ssot_skills() {
  find "$SSOT" \
    \( -name '.venv*' -o -name 'venv' -o -name 'node_modules' -o -name 'site-packages' \
       -o -name '__pycache__' -o -name '.git' -o -name '.archive' -o -name '.curator_backups' \
       -o -name '.curator_state' -o -name '.hub' -o -name '.trash' \) -prune \
    -o -name 'SKILL.md' -printf '%T@\t%p\n' 2>/dev/null
}
newest_skill=$(find_ssot_skills | sort -rn | head -1 | cut -f1)
n_skills=$(find_ssot_skills | wc -l)

graph_epoch=0
graph_files=""
if [ -f "$GRAPH" ]; then
  graph_epoch=$(stat -c %Y "$GRAPH" 2>/dev/null || echo 0)
  graph_files=$(grep -oE 'skill_files: [0-9]+' "$GRAPH" | grep -oE '[0-9]+' | head -1)
fi

say "SSOT: ${n_skills} plikow SKILL.md"
say "graf: ${graph_files:-BRAK} skilli (mtime epoch ${graph_epoch})"

# ── 1. Świeżość: czy graf zna najnowszy skill ───────────────────────────
stale=0
if [ -z "$graph_files" ] || [ "$graph_epoch" -eq 0 ]; then
  say "FAIL: graf nieczytelny albo nie istnieje ($GRAPH)"
  stale=1
elif [ -n "$newest_skill" ]; then
  nk_int="${newest_skill%.*}"
  if [ "$graph_epoch" -lt "$nk_int" ]; then
    say "FAIL: graf STARSZY niz najnowszy skill (graf=$graph_epoch < skill=$nk_int)"
    stale=1
  fi
fi

# ── 2. Kompletność: liczba skilli w grafie vs SSOT ──────────────────────
# UWAGA: graf deduplikuje po `name:` z frontmattera (kanon: 1 nazwa = 1 węzeł
# w grafie). Gdy dwa katalogi deklarują tę samą nazwę, graf ma MNIEJ węzłów
# niż plików — i to jest POPRAWNE, nie defekt. Dlatego tolerujemy różnicę
# równą liczbie duplikatów, którą sam generator raportuje w `duplicates:`.
mismatch=0
dupes=$(grep -oE 'duplicates: [0-9]+' "$GRAPH" 2>/dev/null | grep -oE '[0-9]+' | head -1)
dupes="${dupes:-0}"
expected=$((n_skills - dupes))
if [ -n "$graph_files" ] && [ "$graph_files" -lt "$expected" ]; then
  say "FAIL: graf zna ${graph_files} skilli, oczekiwane >=${expected} (SSOT ${n_skills} - duplikaty ${dupes})"
  mismatch=1
else
  say "OK:   graf ${graph_files:-?} skilli == SSOT ${n_skills} minus ${dupes} duplikatow nazw"
fi

# ── 3. Samonaprawa: regeneruj graf i zmierz PONOWNIE ────────────────────
if { [ "$stale" -eq 1 ] || [ "$mismatch" -eq 1 ]; } && [ "$AUTOFIX" = "1" ]; then
  say "AUTOFIX: regeneruje graf ($GEN)"
  if timeout 300 python3 "$GEN" >/dev/null 2>&1; then
    g2=$(grep -oE 'skill_files: [0-9]+' "$GRAPH" | grep -oE '[0-9]+' | head -1)
    e2=$(stat -c %Y "$GRAPH" 2>/dev/null || echo 0)
    # zmierz ponownie (swiezy graf nie moze byc starszy od najnowszego skilla)
    nk_int="${newest_skill%.*}"
    if [ -n "$g2" ] && [ "$g2" -ge "$n_skills" ] 2>/dev/null && [ "$e2" -ge "$nk_int" ]; then
      say "AUTOFIX OK: graf odswiezony (${g2} skilli)"
      say "UWAGA: graf zmieniony — ZACOMMITUJ config/canonical/skill-graph.yaml"
      # nie blokujemy pusha po udanej naprawie, ale zmiana wymaga commita
      echo "skill-graph-freshness: PASS (graf odswiezony automatycznie)"
      exit 0
    fi
    say "FAIL: AUTOFIX nie domknal rozjazdu (graf=${g2:-?} vs SSOT=${n_skills})"
  else
    say "FAIL: generator zwrocil blad"
  fi
  fails=$((fails+1))
elif [ "$stale" -eq 1 ] || [ "$mismatch" -eq 1 ]; then
  fails=$((fails+1))
  say "Naprawa: python3 $GEN"
fi

if [ "$fails" -eq 0 ]; then
  echo "skill-graph-freshness: PASS (graf zna wszystkie ${n_skills} skilli)"
  exit 0
fi
echo "skill-graph-freshness: FAIL (graf nieaktualny)"
exit 1
