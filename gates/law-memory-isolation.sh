#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/law-memory-isolation.sh — S5-T3 (izolacja pamięci; rozszerza LAW-65)
#
#  PRAWO: pamięć agenta jest jego — obcy proces (inny użytkownik systemu)
#  nie może do niej DOPISAĆ. Pamięć zapisywalna dla „other" = kanał
#  wstrzyknięcia trwałego fałszu do kontekstu każdej kolejnej sesji.
#
#  POMIAR: katalogi pamięci i pliki w nich nie mają bitu o+w.
#  (Współdzielenie przez grupę aigon jest KANONEM — nie jest naruszeniem.)
#  Override: LAW_MI_DIRS (lista katalogów). exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
DIRS="${LAW_MISO_DIRS:-$(ls -d "$HOME"/.claude/projects/*/memory "$HOME"/.hermes/memories "$HOME"/.qwen/memory* "$HOME"/.aigon/memory* 2>/dev/null)}"
fail=0; n=0
for d in $DIRS; do
  [ -d "$d" ] || continue
  n=$((n+1))
  ww=$(find "$d" -maxdepth 2 \( -type f -o -type d \) -perm -o+w 2>/dev/null | head -5)
  if [ -n "$ww" ]; then echo "[FAIL] $d — zapisywalne dla other:"; echo "$ww" | sed 's/^/         /'; fail=1; fi
done
echo "[INFO] zbadanych katalogów pamięci: $n"
[ $fail -eq 0 ] && { echo "law-memory-isolation: PASS"; exit 0; }
echo "law-memory-isolation: FAIL"; exit 1
