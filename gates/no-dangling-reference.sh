#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/no-dangling-reference.sh — gate no-dangling-reference
#
#  AUTOMAT: „Deklaracja musi byc nadal prawdziwa" — sprawdza, czy KAZDA
#  sciezka do skryptu wymieniona w kodzie, docstringu, dokumentacji albo
#  configu FAKTYCZNIE istnieje na dysku.
#
#  DLACZEGO (zmierzone 2026-09-06): sync-agent-models.py w docstringu
#  odsylal do `fix-ollama-slots.sh` jako kanonicznego dystrybutora drop-inow
#  ollamy. Pliku NIE BYLO od dawna. Skutek: nic nie rozsylalo kanonu na nody,
#  profil GPU (keep_alive=-1, duzy ctx) zostal na maszynach BEZ GPU i zajechal
#  je (contabo load 40 na 12 rdzeniach), a load-aware alokator scattera
#  wykluczyl je z mesha — „scatter nie rozprasza" przez ~miesiac.
#
#  Zaden z 46 istniejacych gate'ow tego nie lapal, bo wszystkie sprawdzaja
#  OBECNOSC i REFERENCJE, a nie to, czy deklaracja jest nadal prawdziwa.
#  wired-check przepuszcza martwa zdolnosc, jesli jest polem struct Runtime.
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS (brak wiszacych odwolan poza allowlista)
#    exit 1 = FAIL (odwolanie do nieistniejacego pliku)
#    exit 2 = blad srodowiska
#  Opcje:
#    --json     → raport JSON na stdout
#    --quiet    → bez stdout (tylko exit code)
#    --staged   → tylko pliki w git index (tryb pre-commit)
#
#  Analiza STATYCZNA (grep), bez toolchaina.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOW="$ROOT/tools/gates/dangling-reference-allowlist.txt"
JSON=0; QUIET=0; STAGED=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --quiet) QUIET=1 ;;
    --staged) STAGED=1 ;;
  esac
done

[ -d "$ROOT" ] || { echo "no-dangling-reference: brak ROOT" >&2; exit 2; }

# ZBIERANIE ODWOLAN. ZOPTYMALIZOWANE 2026-09-30 (zmierzone: RC=124 = bramka
# przekraczala limit 420 s — pre-push nie mogl jej ukonczyc).
#   Bylo:  `find` po calym drzewie + N osobnych `grep` (jeden podproces na
#          plik) — w tym korpus datasets/*.jsonl (setki MB) i reports/.
#   Jest:  (a) JEDEN przebieg ripgrepa (LAW-TOOL-1: rg, nie find),
#          (b) wykluczone ciezkie katalogi DANYCH, ktorych bramka nie ma po co
#              skanowac (datasets/, reports/, artifacts/, .qwen/) — to one
#              zjadaly limit czasu,
#          (c) --max-filesize 2M (korpus/JSONL nie jest deklaracja kodu).
# Zakres deklaracji (scripts/…, tools/…) i wykluczenia kodu OBCEGO zostaja.
RG_GLOBS=(
  -g '*.rs' -g '*.py' -g '*.sh' -g '*.yaml' -g '*.yml'
  -g '!**/target/**' -g '!**/node_modules/**' -g '!**/_archive/**'
  -g '!**/backups/**' -g '!**/archive/**' -g '!**/venv/**'
  -g '!**/site-packages/**' -g '!**/.local/**' -g '!**/dist-info/**'
  -g '!**/__pycache__/**' -g '!**/.git/**'
  -g '!**/datasets/**' -g '!**/reports/**' -g '!**/artifacts/**'
  -g '!**/.qwen/**' -g '!data/**' -g '!agent-env/**'
  # Drzewa poza ZAKRESEM DEKLARACJI PLATFORMY. ZMIERZONE 2026-09-30: 586 z 785
  # wiszacych odwolan pochodzilo stad — to nie sa nasze deklaracje:
  #   products/    — per-produktowe KOPIE platformy (wlasne sciezki wzgledne),
  #   out/         — artefakty builda,  bench/ — korpusy benchmarkow,
  #   mcp-servers/ — vendored serwery MCP,  deployment/ — szablony wdrozen,
  #   wojsko/      — archiwum (z-archiwum-*),  runtime-bin/ — binarki.
  -g '!products/**' -g '!out/**' -g '!bench/**' -g '!mcp-servers/**'
  -g '!deployment/**' -g '!wojsko/**' -g '!runtime-bin/**'
  # runtime-headcheck/ — CUDZY checkout benchmarku (LiveBench / agentic shootout),
  # ZMIERZONE 2026-10-01: jego skrypty odwoluja wlasne scripts/* ktorych u nas nie ma
  # (0 z tych odwolan nalezy do products/agent-sniegul — moj zakres czysty). To
  # NIE jest nasza deklaracja platformy — tak samo jak out/ i bench/.
  -g '!runtime-headcheck/**'
)
# GRANICA LEWA (ZMIERZONE 2026-09-30, defekt wlasny): bez niej regex lapal OGON
# dluzszej, istniejacej sciezki — skrypt produktu leonardo, pod pelna sciezka
# products/akceleratory/leonardo/tools/leonardo-staging-metric.sh (plik ISTNIEJE),
# byl raportowany skrocona forma jako nieistniejacy => falszywy FAIL na cudzej,
# poprawnej pracy. UWAGA dla przyszlych komentarzy: ten plik jest skanowany
# TAKZE U SIEBIE, wiec kazdy repo-wzgledny token katalog/plik na granicy slowa
# staje sie zadeklarowanym celem — ta sama klasa zlamala GATE-126 (literal
# z komentarza manifestu liczony jako kernel). `-o` gubi znak poprzedzajacy,
# wiec granicy nie da sie sprawdzic w samym ripgrepie; ekstrakcje robi python
# z lookbehindem (rg zostaje jako szybki prefiltr linii).
PY_REF='import sys, re
rx = re.compile(r"(?<![A-Za-z0-9_./-])((scripts|tools)/[A-Za-z0-9_./-]+\.(sh|py))")
seen = set()
for line in sys.stdin:
    line = line.rstrip("\n")
    if ":" not in line:
        continue
    f, rest = line.split(":", 1)
    for m in rx.finditer(rest):
        k = (f, m.group(1))
        if k in seen:
            continue
        seen.add(k)
        print("%s:%s" % (f, m.group(1)))'
zbierz_odwolania() {
  if [ "$STAGED" = "1" ]; then
    git -C "$ROOT" diff --cached --name-only --diff-filter=ACM 2>/dev/null \
      | grep -E '\.(rs|py|sh|md|yaml|yml)$' \
      | xargs -r -d '\n' rg --no-heading --no-messages --no-ignore --line-number \
          --max-filesize 2M \
          -e '(scripts|tools)/[A-Za-z0-9_./-]+\.(sh|py)' 2>/dev/null \
      | python3 -c "$PY_REF"
  else
    rg --no-heading --no-messages --no-ignore --line-number \
       --max-filesize 2M "${RG_GLOBS[@]}" \
       -e '(scripts|tools)/[A-Za-z0-9_./-]+\.(sh|py)' "$ROOT" 2>/dev/null \
      | python3 -c "$PY_REF"
  fi
}

# Wyciaga odwolania do skryptow repo. Celowo WASKI wzorzec: tylko literalne
# sciezki z prefiksem scripts/ lub tools/. Zmienne ($VAR/foo.sh) i sciezki
# budowane w runtime sa POMIJANE — gate ma nie generowac szumu.
ref_istnieje() {  # <plik_deklarujacy> <ref> — ROOT albo wzgledem katalogu pliku
  local f="$1" ref="$2" d nd
  case "$f" in /*) ;; *) f="$ROOT/$f" ;; esac
  [ -e "$ROOT/$ref" ] && return 0
  d="$(dirname "$f")"
  while [ -n "$d" ]; do
    [ -e "$d/$ref" ] && return 0
    nd="$(dirname "$d")"
    [ "$nd" = "$d" ] && break
    [ "${#nd}" -lt "${#ROOT}" ] && break
    d="$nd"
  done
  return 1
}

wisi=""
liczba_ref=0
# Wiersze z rg: "<sciezka>:<odwolanie>" (--with-filename). Jeden przebieg na
# wszystkie pliki zamiast petli grep per plik.
while IFS= read -r _line; do
  [ -n "$_line" ] || continue
  f="${_line%%:*}"
  ref="${_line#*:}"
  [ -n "$ref" ] || continue
  # Tylko literalne sciezki repo (zmienne i budowane w runtime pomijamy).
  case "$ref" in *'$'*|*'{'*|*'*'*|*'('*|*')'*) continue ;; esac
  liczba_ref=$((liczba_ref + 1))
  # ROZWIĄZYWANIE (ZMIERZONE 2026-09-30): odwolanie w dokumencie skilla jest
  # czesto WZGLEDNE wobec katalogu tego skilla (skill ma wlasne scripts/),
  # a nie wobec repo — bez tego 45 z 76 celow bylo falszywymi "wisiacymi"
  # (np. skills/shared/sovereign-deep-search/README.md mowi `scripts/atlas.py`,
  # a plik lezy w skills/shared/sovereign-deep-search/scripts/atlas.py).
  # Cel uznajemy za istniejacy, gdy znajdziemy go w ROOT albo w ktoryms
  # katalogu-nadrzednym pliku deklarujacego (nie wyzej niz ROOT).
  ref_istnieje "$f" "$ref" && continue
  if [ -f "$ALLOW" ] && grep -qxF "$ref" "$ALLOW" 2>/dev/null; then continue; fi
  wisi="${wisi}${f#$ROOT/}|${ref}"$'\n'
done < <(zbierz_odwolania | sort -u)

wisi="$(printf '%s' "$wisi" | sed '/^$/d' | sort -u)"
ile=$(printf '%s' "$wisi" | grep -c . || true)

# ── RATCHET ZASTANEGO DLUGU (2026-09-30) ──────────────────────────────────
# ZMIERZONE: po zawezeniu zakresu zostaje ~100 odwolan do nieistniejacych
# celow, rozproszonych po skills/ (proza i przyklady), docs/ i config/
# (zadeklarowane, nieimplementowane skrypty). Ta bramka jest warunkiem
# PRE-PUSH dla WSZYSTKICH agentow — FAIL na ZASTANYM dlugu blokowal push
# calemu zespolowi (a dodatkowo bramka konczyla sie timeoutem).
# Wzorzec jak state-baseline / ratchet mesha: NOWE wiszace odwolanie = FAIL,
# zastany dlug = INFO z jawnym licznikiem do spalania. Baseline jest w gicie.
BASELINE="$ROOT/tools/gates/dangling-reference-baseline.txt"
NOWE=""; ZNANE=0
while IFS='|' read -r _f _r; do
  [ -n "$_r" ] || continue
  if [ -f "$BASELINE" ] && grep -qxF "$_r" "$BASELINE" 2>/dev/null; then
    ZNANE=$((ZNANE + 1))
  else
    NOWE="${NOWE}${_f}|${_r}"$'\n'
  fi
done <<< "$wisi"
NOWE="$(printf '%s' "$NOWE" | sed '/^$/d' | sort -u)"
ile_nowe=$(printf '%s' "$NOWE" | grep -c . || true)

if [ "$JSON" = "1" ]; then
  printf '{"gate":"no-dangling-reference","sprawdzonych_odwolan":%d,"wiszacych":%d,"znanych_w_baseline":%d,"nowych":%d,"pozycje":[' \
    "$liczba_ref" "$ile" "$ZNANE" "$ile_nowe"
  sep=""
  while IFS='|' read -r plik ref; do
    [ -n "$plik" ] || continue
    printf '%s{"plik":"%s","odwolanie":"%s"}' "$sep" "$plik" "$ref"; sep=","
  done <<< "$NOWE"
  printf ']}\n'
elif [ "$QUIET" != "1" ]; then
  if [ "$ile_nowe" -eq 0 ]; then
    echo "no-dangling-reference: PASS — $liczba_ref odwolan; nowych wiszacych: 0 (zastany dlug w baseline: $ZNANE)"
    if [ "$ZNANE" -gt 0 ]; then
      echo "  Dlug do spalenia: usun odwolanie/plik, potem skresl cel z tools/gates/dangling-reference-baseline.txt."
    fi
  else
    echo "no-dangling-reference: FAIL — $ile_nowe NOWYCH wiszacych odwolan (z $liczba_ref; zastany dlug w baseline: $ZNANE):"
    while IFS='|' read -r plik ref; do
      [ -n "$plik" ] || continue
      echo "  $plik -> $ref (NIE ISTNIEJE)"
    done <<< "$NOWE"
    echo "  Napraw sciezke, dopisz do tools/gates/dangling-reference-allowlist.txt (ZAMIERZONE) albo — gdy dlug zastany — dopisz do baseline z uzasadnieniem."
  fi
fi

[ "$ile_nowe" -eq 0 ]
