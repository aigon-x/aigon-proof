#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-context-integrity.sh — S4-T3 (integralność kontekstu)
#
#  PRAWO: kanon, który agent DOSTAJE w kontekście, jest kompletny i
#  pochodzi z SSOT. Cichy brak dołączonego pliku (@include do pliku,
#  którego nie ma albo jest pusty) = agent działa na OBCIĘTYM kanonie
#  i nikt tego nie widzi — prompt startuje bez błędu.
#
#  POMIAR:
#    (1) każdy `@<ścieżka>` w plikach instrukcji agentów wskazuje na
#        ISTNIEJĄCY, NIEPUSTY, CZYTELNY plik;
#    (2) pliki generowane z SSOT niosą nagłówek pochodzenia
#        („NIE EDYTOWAĆ"/„generowane z"), czyli da się wskazać ich źródło.
#  Override: LAW_CI_FILES (lista plików instrukcji). exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
FILES="${LAW_CI_FILES:-$HOME/.claude/CLAUDE.md /srv/aigon/AGENTS.md $HOME/.qwen/AGENTS.md $HOME/.hermes/AGENTS.md}"
GEN="${LAW_CI_GENERATED:-$HOME/.claude/CLAUDE.md}"
fail=0; inc=0
for f in $FILES; do
  [ -f "$f" ] || { echo "[INFO] pomijam (brak): $f"; continue; }
  d=$(dirname "$f")
  while read -r ref; do
    [ -n "$ref" ] || continue
    inc=$((inc+1))
    case "$ref" in /*) p="$ref";; *) p="$d/$ref";; esac
    if [ -s "$p" ] && [ -r "$p" ]; then :
    else echo "[FAIL] $f -> @$ref : brak/pusty/nieczytelny — kanon w kontekście OBCIĘTY"; fail=1; fi
  done < <(grep -oE '^@[^[:space:]]+' "$f" | sed 's/^@//')
done
echo "[INFO] zbadanych dołączeń @: $inc"
for g in $GEN; do
  [ -f "$g" ] || continue
  if head -5 "$g" | grep -qiE 'NIE EDYTOWA|generowane z|generated from'; then
    echo "[PASS] $g — nagłówek pochodzenia SSOT obecny"
  else echo "[FAIL] $g — brak nagłówka pochodzenia (nie wiadomo, skąd kanon)"; fail=1; fi
done
[ $fail -eq 0 ] && { echo "law-context-integrity: PASS"; exit 0; }
echo "law-context-integrity: FAIL"; exit 1
