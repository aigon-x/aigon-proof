#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/canonical-route.sh — BRAMKA KANONU (GATE-CANON-1)
#
#  Cel: ZANIM zacznie się praca, brief musi wskazać kanoniczną trasę
#  operacji (deploy, transfer, sync, zmiana configu). Ręczne obejścia
#  (docker save | ssh docker load, scp/rsync drzewa produktu, docker cp)
#  są FAIL-em, chyba że Suweren jawnie uchyli kanon.
#
#  Użycie:
#    canonical-route.sh --brief <plik>      # start zadania / pipeline'u
#    canonical-route.sh --command "<cmd>"   # sprawdź planowaną komendę
#    canonical-route.sh --selftest          # test negatywny bramki
#    canonical-route.sh                     # tryb verify: brief z env lub domyślny
#
#  Override: AIGON_CANON_OVERRIDE="powód" (tylko po jawnej zgodzie Suwerena)
#            albo w briefie: override: "user: <powód>"
#  SSOT tras: config/canonical/canonical-route.yaml
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/srv/aigon}"
BRIEF=""; COMMAND=""; SELFTEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --brief)   BRIEF="${2:-}"; shift 2 ;;
    --command) COMMAND="${2:-}"; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "FAIL: nieznany argument: $1"; exit 2 ;;
  esac
done

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; exit 0; }

BANNED=(
  'docker[[:space:]]+save.*\|.*ssh.*docker[[:space:]]+load'
  'ssh[[:space:]].*docker[[:space:]]+(save|load)'
  '(scp|rsync)[[:space:]].*(prod-aigon|contabo|100\.99\.59\.100|100\.77\.55\.117)'
  'docker[[:space:]]+cp.*(prod-aigon|contabo|100\.99\.59\.100|100\.77\.55\.117)'
  'docker[[:space:]]+compose[[:space:]]+build.*&&.*(scp|rsync)'
)

check_text() {
  local text="$1" label="$2"
  if printf '%s' "$text" | grep -qiE 'override[[:space:]]*:[[:space:]]*(user|suweren|sovereign)|AIGON_CANON_OVERRIDE[[:space:]]*='; then
    echo "WARN: jawny override kanonu ($label) — sprawdź, czy Suweren tak powiedział"
    return 0
  fi
  local p
  for p in "${BANNED[@]}"; do
    if printf '%s' "$text" | grep -qEi -- "$p"; then
      local pretty
      pretty="$(printf '%s' "$p" | sed -E 's/\[\[:space:\]\]\+/ /g')"
      fail "$label: wykryto ręczne obejście kanonu ($pretty). Użyj trasy z config/canonical/canonical-route.yaml albo poproś Suwerena o override."
    fi
  done
  return 0
}

if [ "$SELFTEST" -eq 1 ]; then
  # 1) ręczny transfer = FAIL
  ( check_text 'docker save img | ssh prod-aigon docker load' selftest >/dev/null 2>&1 ) \
    && fail "selftest: ręczny transfer NIE został złapany" || true
  # 2) kanoniczna trasa = PASS
  check_text 'canonical_route: /srv/aigon/products/optiq/tools/deploy-all.sh' selftest >/dev/null \
    || fail "selftest: kanoniczna trasa została odrzucona"
  # 3) override = PASS z ostrzeżeniem
  check_text 'override: user: świadoma decyzja Suwerena' selftest >/dev/null \
    || fail "selftest: override został odrzucony"
  # 4) scp do node = FAIL
  ( check_text 'scp -r build prod-aigon:/srv/aigon' selftest >/dev/null 2>&1 ) \
    && fail "selftest: scp do node NIE został złapany" || true
  pass "selftest 4/4 (2× FAIL złapany, 2× PASS przepuszczony)"
fi

if [ -n "$COMMAND" ]; then
  check_text "$COMMAND" "command"
  pass "komenda nie zawiera ręcznego obejścia kanonu"
fi

if [ -z "$BRIEF" ]; then
  BRIEF="${AIGON_TASK_BRIEF:-}"
fi
if [ -z "$BRIEF" ]; then
  for candidate in "$ROOT/reports/task-brief.yaml" "$ROOT/reports/task-brief.yml" "$ROOT/TASK-BRIEF.yaml"; do
    [ -f "$candidate" ] && BRIEF="$candidate" && break
  done
fi

if [ -z "$BRIEF" ]; then
  echo "WARN: brak briefu (AIGON_TASK_BRIEF / reports/task-brief.yaml) — bramka nie ma czego sprawdzić."
  pass "brak briefu: brak operacji do zablokowania"
fi
[ -f "$BRIEF" ] || fail "brak pliku briefu: $BRIEF"

TEXT="$(cat "$BRIEF")"
check_text "$TEXT" "brief"

# Brief startowy MUSI mieć cel, zakres i trasę (albo jawne 'none' dla analizy).
grep -qiE '^[[:space:]]*(cel|goal)[[:space:]]*:' <<<"$TEXT" \
  || fail "brief bez 'cel:' — nie wiadomo, co ma być osiągnięte"
grep -qiE '^[[:space:]]*(zakres|scope)[[:space:]]*:' <<<"$TEXT" \
  || fail "brief bez 'zakres:' — zadanie bez granic"

ROUTE="$(grep -iE '^[[:space:]]*(canonical_route|kanon_route|route)[[:space:]]*:' <<<"$TEXT" | head -1 | sed -E 's/^[^:]+:[[:space:]]*//; s/[[:space:]]*$//')"
if [ -z "$ROUTE" ]; then
  fail "brief bez 'canonical_route:' — wskaż kanoniczny skrypt albo 'none' (analiza/odczyt)"
fi
if [ "$ROUTE" = "none" ] || [ "$ROUTE" = "brak" ]; then
  if grep -qiE '^[[:space:]]*(typ|operation|operacja)[[:space:]]*:[[:space:]]*(analiza|analysis|read|odczyt)' <<<"$TEXT"; then
    pass "brak operacji wdrożeniowej — trasa 'none' dopuszczalna dla analizy"
  fi
  fail "trasa 'none' wymaga 'typ: analiza' — inaczej brak kanonicznej drogi"
fi
ROUTE="${ROUTE%%[[:space:]]#*}"
[ -e "$ROUTE" ] || fail "wskazana trasa nie istnieje: $ROUTE"
if [ -x "$ROUTE" ]; then
  pass "brief wskazuje kanoniczną trasę: $ROUTE"
fi
fail "wskazana trasa nie jest wykonywalna: $ROUTE"
