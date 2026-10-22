#!/usr/bin/env bash
# ============================================================================
# system-bin-perms-guard.sh — STRAZNIK UPRawnien BINAREK SYSTEMOWYCH
#
# PO CO (incydent 2026-09-29, zmierzony): /usr/bin/python3.12 mial
#   -rw-r--r-- aigon:aigon   <- BRAK bitu +x, wlasciciel aigon
# Objaw: KAZDY skrypt wolajacy `python3` w cronie/bramce/watchdogu padal na
# "/usr/bin/python3: Brak dostepu". Runtime raportowal zdrowie, bramki
# przechodzily w tych sciezkach, ktore nie wolaja python3 — awaria byla
# NIEWIDOCZNA do momentu recznego uruchomienia.
#
# KLASA BLEDU (nie pojedynczy plik): proces agenta z prawami zapisu do
# /usr/bin moze nadpisac binarke systemowa (np. `cp`/redirect zamiast
# instalacji), gubiac bit +x i wlasciciela root. Ten sam wzorzec dotyczyl
# /usr/bin/orca (tryb 000 — calkowicie zablokowany).
#
# REGULY:
#   R1. plik wykonywalny (shebang lub ELF) w /usr/bin i /usr/local/bin
#       MUSI miec +x. Brak +x => FAIL.
#   R2. binarka systemowa w /usr/bin MUSI byc root:root. Nie-root wlasciciel
#       => agent nadpisal plik systemowy => FAIL.
#   R3. tryb 000 (brak jakiegokolwiek bitu) => FAIL (ktoś zablokowal plik).
#
# Wyjatki (nie sa binarkami): rozszerzenia .md .jar .1 .txt .json .yaml
# .yml .conf .service .report .bak .log .gz oraz katalogi.
#
# Bramka: config/canonical/gates.yaml -> system-bin-perms-guard
# ============================================================================
set -uo pipefail

FAILED=0
declare -a REASONS=()

is_binary() {
  local f="$1"
  case "${f##*/}" in
    *.md|*.jar|*.1|*.txt|*.json|*.yaml|*.yml|*.conf|*.service|*.report|*.bak|*.log|*.gz|*.html|*.css|*.js.map)
      return 1 ;;
  esac
  [ -f "$f" ] || return 1
  # Plik z trybem 000 nie da sie odczytac -> ale jest KANDYDATEM na binarke,
  # jesli lezy w katalogu binarek i nie ma rozszerzenia danych (sprawdzone
  # wyzej). Nie odrzucamy go tylko dlatego, ze nie mozemy zajrzec do srodka.
  local p; p=$(stat -c '%a' "$f" 2>/dev/null)
  if [ "$p" = "0" ] || [ "$p" = "000" ]; then
    return 0
  fi
  # shebang albo ELF
  head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF' && return 0
  head -1 "$f" 2>/dev/null | grep -q '^#!' && return 0
  return 1
}

for dir in /usr/bin /usr/local/bin; do
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    is_binary "$f" || continue
    perm=$(stat -c '%a' "$f" 2>/dev/null)
    owner=$(stat -c '%U' "$f" 2>/dev/null)
    if [ "$perm" = "0" ] || [ "$perm" = "000" ]; then
      REASONS+=("$f tryb 000 — plik calkowicie zablokowany")
      FAILED=1
      continue
    fi
    if [ $(( 0$perm & 0111 )) -eq 0 ]; then
      REASONS+=("$f brak bitu +x (tryb $perm) — kazde wykonanie padnie")
      FAILED=1
    fi
    if [ "$dir" = "/usr/bin" ] && [ "$owner" != "root" ]; then
      REASONS+=("$f binarka systemowa wlasciciel=$owner (oczekiwano root) — nadpisana przez agenta")
      FAILED=1
    fi
  done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
done

if [ "$FAILED" -eq 1 ]; then
  printf 'system-bin-perms-guard: FAIL'
  for x in "${REASONS[@]}"; do printf ' | %s' "$x"; done
  printf '\n'
  printf '  NAPRAWA: sudo chown root:root <plik> && sudo chmod 755 <plik>\n'
  exit 1
fi

printf 'system-bin-perms-guard: PASS (binarki /usr/bin + /usr/local/bin maja +x i wlasciciela)\n'
exit 0
