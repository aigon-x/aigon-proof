#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  parallel-omnipotence-guard.sh — egzekutor LAW-PARALLEL-OMNIPOTENCE-1
#  "MOC RÓWNOLEGŁOŚCI RUNTIME — NIE MA DLA NAS RZECZY NIEMOŻLIWYCH"
#  Wykrywa WYMIÓWKĘ CZASOWĄ użyta jako BLOKADA (pominięcie kroku / zwężenie
#  zakresu / "failed" / "nie da się") w: (1) ostatnich wpisach ledgera
#  ~/.aigon/todo/*.ndjson, (2) ostatnich 30 wiadomościach commitów.
#  ADVISORY: domyślnie WARN (exit 0). --strict => FAIL. --selftest => testy.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
STRICT=0; SELFTEST=0; HITS=0; SCANNED=0
for a in "$@"; do case "$a" in --strict) STRICT=1;; --selftest) SELFTEST=1;; esac; done

PATTERNS=(
  'mamy tylko [0-9]+ (dni|dzień|godzin|minut)'
  'za ma[łl]o czasu'
  'nie (zd[ąa][żz]ymy|starczy czasu|wystarczy czasu)'
  'brak czasu (na|by)'
  'nie da si[eę] (tego )?(zrobi[ćc]|wykona[ćc])'
)

scan_text() {  # $1 = etykieta; stdin = tekst
  local src="$1" ln=0 line p
  while IFS= read -r line; do
    ln=$((ln+1)); SCANNED=$((SCANNED+1))
    for p in "${PATTERNS[@]}"; do
      if grep -qiE "$p" <<<"$line"; then
        HITS=$((HITS+1))
        printf 'WARN [parallel-omnipotence] %s:%s :: %s\n' "$src" "$ln" "$(printf '%s' "$line" | cut -c1-160)"
      fi
    done
  done
}

if [ "$SELFTEST" = 1 ]; then
  ok=1
  n=$(HITS=0; SCANNED=0; scan_text '<test>' <<<"na to mamy tylko 2 dni, wiec pomijam krok" >/dev/null; printf '%s' "$HITS")
  [ "${n:-0}" -ge 1 ] || { echo "SELFTEST FAIL: nie złapałem wstrzykniętej wymówki"; ok=0; }
  m=$(HITS=0; SCANNED=0; scan_text '<test>' <<<"zadanie wykonane rownolegle przez scatter, 8 strumieni, dowod w ledgerze" >/dev/null; printf '%s' "$HITS")
  [ "${m:-0}" -eq 0 ] || { echo "SELFTEST FAIL: fałszywe trafienie na czystym tekście"; ok=0; }
  [ "$ok" = 1 ] && echo "SELFTEST PASS (pozytywny=złapany, negatywny=czysty)" || exit 1
  exit 0
fi

for f in "$HOME"/.aigon/todo/*.ndjson; do
  [ -f "$f" ] || continue
  tail -n 400 "$f" 2>/dev/null | scan_text "$f"
done
if git -C /srv/aigon rev-parse --git-dir >/dev/null 2>&1; then
  git -C /srv/aigon log -n 30 --pretty=format:'%s %b' 2>/dev/null | scan_text "git:last30"
fi

if [ "$HITS" -gt 0 ]; then
  if [ "$STRICT" = 1 ]; then echo "FAIL [parallel-omnipotence] $HITS wymówek czasowych (strict)"; exit 1; fi
  echo "WARN [parallel-omnipotence] $HITS podejrzanych wymówek / $SCANNED linii (advisory; --strict => FAIL)"; exit 0
fi
echo "PASS [parallel-omnipotence] brak wymówki czasowej ($SCANNED linii)"; exit 0
