#!/usr/bin/env bash
# scan-ssot-vs-agent-copy-drift.sh — wykryj rozjazd SSOT (skills/shared) vs kopia agenta
#
# PO CO: agent pisze/przypina skill przez skill_manage → zapis trafia do KOPII AGENTA
# (~/.hermes/skills/...), a manifest i rejestr wskazują na SSOT (skills/shared/<n>/).
# Nic nie promuje kopii agenta z powrotem, więc rozjazd narasta po cichu: rejestr
# serwuje stub, sync roznosi stub, a każdy kolejny sync MOŻE nadpisać świeżą kopię.
# Zmierzone 2026-09-28 na lokalnej bazie: 285 z 798 porównanych skilli rozjechanych,
# bogatsza zwykle kopia AGENTA (×2,2 … ×4,4).
#
# Ta sonda jest READ-ONLY — raportuje, nie naprawia. Naprawa to świadoma decyzja:
# najpierw DOWÓD PODZBIORU (0 linii istnieje wyłącznie w kopii nadpisywanej), potem
# `cp -a <bogata>/. <cel>/` + chown/chmod + kanoniczny ingest.
#
# Użycie:
#   bash scan-ssot-vs-agent-copy-drift.sh [ROOT] [SKILLS_DIR_AGENTA]
#   ROOT=/srv/aigon                                        (default)
#   SKILLS_DIR_AGENTA=/home/$USER/.hermes/skills          (default)
#
# Kontrakt: 0 = brak rozjazdu; 1 = znaleziono rozjazd(y); 2 = błąd użycia.
set -uo pipefail

ROOT="${1:-${AIGON_PROD_ROOT:-/srv/aigon}}"
HS="${2:-$HOME/.hermes/skills}"
SHARED="$ROOT/skills/shared"

[ -d "$SHARED" ] || { echo "brak $SHARED — zły ROOT?" >&2; exit 2; }
[ -d "$HS" ]     || { echo "brak $HS — podaj katalog skilli agenta" >&2; exit 2; }

n=0; div=0
printf '%-52s %9s %9s  %s\n' SKILL SSOT_B kopia_B WERDYKT
while IFS= read -r sdir; do
  name=$(basename "$sdir")
  [ -f "$sdir/SKILL.md" ] || continue
  kopia=$(find "$HS" -maxdepth 2 -type d -name "$name" 2>/dev/null | head -1)
  [ -n "$kopia" ] && [ -f "$kopia/SKILL.md" ] || continue
  n=$((n+1))
  a=$(stat -c %s "$sdir/SKILL.md"); b=$(stat -c %s "$kopia/SKILL.md")
  fa=$(find "$sdir" -type f | wc -l); fb=$(find "$kopia" -type f | wc -l)
  if [ "$a" != "$b" ] || [ "$fa" != "$fb" ]; then
    div=$((div+1))
    ratio=$(awk -v x="$a" -v y="$b" 'BEGIN{printf "%.1f", (y>0? y/x : 0)}')
    # kierunek: x>1 → bogatsza kopia agenta; x<1 → bogatszy SSOT
    dir_="kopia-agent > SSOT"; [ "$(awk -v r="$ratio" 'BEGIN{print (r<1)}')" = "1" ] \
      && dir_="SSOT > kopia-agent"
    printf '%-52s %9s %9s  %s (x%s, pliki %s vs %s)\n' "$name" "$a" "$b" "$dir_" "$ratio" "$fa" "$fb"
  fi
done < <(find "$SHARED" -maxdepth 1 -mindepth 1 -type d | sort)

echo "---"
echo "porownanych: $n | rozjechanych: $div"
echo
echo "DOWOD PODZBIORU dla wybranego artefaktu (0 = promocja nic nie traci):"
echo "  diff <(sort -u \"$SHARED/<n>/SKILL.md\") <(sort -u \"$HS/*/<n>/SKILL.md\") | grep -c '^<'"
echo "AUTORYTET rejestru (co naprawde serwowane):"
echo "  docker exec aigon-datastores-postgres psql -U aigon -d aigoncode -tAc \\"
echo "    \"select name, length(content), source_path from skills where name='<n>';\""

[ "$div" -eq 0 ] && exit 0 || exit 1
