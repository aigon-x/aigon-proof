#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/runtime-build.sh — GATE-129: CZY *ZACOMMITOWANE* DRZEWO
#  RUNTIME SIE KOMPILUJE (hook-runner; trigger: cyclic:hourly)
#
#  PO CO (incydent zmierzony 2026-09-22):
#    Pre-push mial bramki skladni, sekretow, tozsamosci, kanonu, tierow i
#    placementu — ale ANI JEDNEJ, ktora kompiluje runtime. Commit 4bda677a
#    wprowadzil wolanie `cg.expire_idle()` w aigon-runtime/src/lib.rs,
#    a implementacje zostawil w WIP. Drzewo przestalo sie kompilowac —
#    i przez 45 commitow nikt tego nie zauwazyl (wszystkie bramki zielone).
#    Wszystkie 45 sa na origin.
#
#  ⚠️ PULAPKA, KTOREJ TA BRAMKA NIE MOZE POPELNIC (zmierzona przy pierwszej
#  wersji tego skryptu): `cargo check` w katalogu repo kompiluje DRZEWO
#  ROBOCZE, a nie HEAD. Gdy implementacja lezy niezacommitowana na dysku
#  (a tak bylo tutaj!), cargo check przechodzi i bramka melduje PASS —
#  mimo ze HEAD jest niekompilowalny. To fasada: zielone swiatlo nad
#  zepsutym stanem, czyli dokladnie klasa, ktora mamy wykrywac.
#  Dlatego sprawdzamy w IZOLOWANYM WORKTREE na HEAD — na dysku nie patrzymy.
#
#  KONTRAKT: exit 0 = PASS/WARN, exit 1 = FAIL.
#    FAIL tylko gdy cargo REALNIE zglasza bledy kompilacji drzewa z HEAD.
#    "Nie moge sprawdzic" (brak cargo/git/worktree/timeout) = WARN (exit 0):
#    falszywy FAIL na bramce godzinowej jest szumem i nic nie mowi o drzewie.
#
#  Zmienne env:
#    AIGON_RUNTIME_BUILD_PKGS     — co sprawdzac (default: "-p aigon-runtime")
#    AIGON_RUNTIME_BUILD_TIMEOUT  — sekundy (default 1800; pierwszy run jest zimny)
#    AIGON_RUNTIME_BUILD_WT       — katalog worktree (default /srv/aigon/runtime-headcheck)
#    AIGON_CARGO                  — sciezka do cargo (default ~/.cargo/bin/cargo)
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG="${AIGON_RUNTIME_BUILD_LOG:-/var/log/aigon/runtime-build.log}"
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/gate-params.sh"
TIMEOUT="$(gp GATE-129 runtime_build_timeout_s 1800)"
PKGS="${AIGON_RUNTIME_BUILD_PKGS:--p aigon-runtime}"
WT="${AIGON_RUNTIME_BUILD_WT:-$ROOT/runtime-headcheck}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG" 2>/dev/null || true; }
warn() { echo "runtime-build: WARN ($1)"; log "WARN: $1"; exit 0; }

# Cargo bywa poza PATH w srodowisku nieinteraktywnym (hook-runner/cron).
CARGO="${AIGON_CARGO:-$HOME/.cargo/bin/cargo}"
[ -x "$CARGO" ] || CARGO="$(command -v cargo 2>/dev/null || true)"
[ -n "$CARGO" ] && [ -x "$CARGO" ] || warn "brak cargo — nie stwierdzam kompilowalnosci"

GIT="$(command -v git 2>/dev/null || echo /usr/bin/git)"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || warn "brak repozytorium git w $ROOT"

HEAD_SHA="$("$GIT" -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"
[ -n "$HEAD_SHA" ] || warn "nie odczytam HEAD"

# ── Izolowany worktree na HEAD (bez ruszania drzewa roboczego i indeksu) ──
if [ -e "$WT" ]; then
  "$GIT" -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT" 2>/dev/null
fi
if ! "$GIT" -C "$ROOT" worktree add --detach --quiet "$WT" HEAD >/dev/null 2>&1; then
  warn "nie utworze worktree na HEAD ($WT) — pomijam przebieg"
fi

cleanup() {
  "$GIT" -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT" 2>/dev/null
}
trap cleanup EXIT

[ -d "$WT/runtime" ] || warn "worktree bez katalogu runtime/"

OUT="$(mktemp)"
cd "$WT/runtime" || warn "nie wchodze do $WT/runtime"

# Staly katalog target dla sprawdzen HEAD (env: AIGON_RUNTIME_BUILD_TARGET).
# Dlaczego osobny i staly: (1) nie zasmiecamy ani nie blokujemy glownego
# runtime/target, ktorym buduja inni agenci; (2) STALA sciezka worktree
# (/srv/aigon/runtime-headcheck) sprawia, ze od drugiego przebiegu cargo
# korzysta z cache i sprawdzenie jest przyrostowe — inaczej kazda godzina
# startowalaby zimny pelny build. Pierwszy przebieg jest zimny (minuty).
export CARGO_TARGET_DIR="${AIGON_RUNTIME_BUILD_TARGET:-$ROOT/runtime/target-headcheck}"

# shellcheck disable=SC2086 — PKGS to celowo lista slow
timeout "$TIMEOUT" "$CARGO" check $PKGS --quiet 2>"$OUT" >/dev/null
RC=$?

if [ "$RC" -eq 0 ]; then
  echo "runtime-build: PASS (HEAD $HEAD_SHA — cargo check $PKGS na zacommitowanym drzewie)"
  log "PASS HEAD=$HEAD_SHA ($PKGS)"
  rm -f "$OUT"
  exit 0
fi

if [ "$RC" -eq 124 ]; then
  warn "cargo check przekroczyl ${TIMEOUT}s na HEAD $HEAD_SHA — nie stwierdzam"
fi

ERRN="$(grep -c -E '^error(\[E[0-9]+\])?:' "$OUT" 2>/dev/null || echo 0)"
if [ "${ERRN:-0}" -gt 0 ]; then
  FIRST="$(grep -m3 -E '^error(\[E[0-9]+\])?:' "$OUT" 2>/dev/null | tr '\n' ' ' | cut -c1-340)"
  echo "runtime-build: FAIL (HEAD $HEAD_SHA NIE kompiluje sie — ${ERRN} bledow; pierwsze: ${FIRST})"
  log "FAIL HEAD=$HEAD_SHA: ${ERRN} bledow"
  rm -f "$OUT"
  exit 1
fi

FIRST="$(tail -3 "$OUT" 2>/dev/null | tr '\n' ' ' | cut -c1-340)"
warn "cargo rc=$RC bez bledow kompilacji na HEAD $HEAD_SHA — srodowisko: ${FIRST}"
