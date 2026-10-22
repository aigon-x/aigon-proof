#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/build-placement.sh — GATE LAW-BUILD-PLACEMENT-1
#
#  KANON (config/canonical/builders.yaml): ciężkie buildy NIGDY na
#  local-aigon (stanowisko + GPU do rozmowy) ani na węźle produkcyjnym —
#  tylko na dedykowanych builderach (VM 110 na PVE) albo w HPC.
#
#  PO CO TA BRAMKA: prawo miało dotąd tylko WATCHDOG (metryka
#  aigon_build_on_workstation + span), a watchdog NIE blokuje. „Prawo bez
#  bramki = życzenie”. Ta bramka zamienia naruszenie położenia builda w FAIL.
#
#  CO MIERZY: procesy budujące (cargo build / rustc --crate / nix build /
#  mksquashfs / docker build) trwające > PROG_MIN minut, na hoście z listy
#  AIGON_BUILD_HOSTS (domyślnie local-aigon).
#
#  KONTRAKT: 0 = PASS, 1 = FAIL, 2 = UNKNOWN (nie da się zmierzyć).
#  --selftest: dowód negatywny — tworzy proces z argv „cargo build” i MUSI
#  go wykryć (bramka, która nie gryzie, nie istnieje).
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/opt/PROD}"
SELFTEST=0; [ "${1:-}" = "--selftest" ] && SELFTEST=1
PROG_MIN="${AIGON_BUILD_PROG_MIN:-10}"
HOST="$(hostname -s)"
WAZNE="${AIGON_BUILD_HOSTS:-local-aigon}"
PATS=('cargo build' 'rustc --crate' 'nix build' 'mksquashfs' 'docker build')

scan() {   # scan <prog_min> -> "count<TAB>lines"
    local prog="$1" n=0 out=""
    for p in "${PATS[@]}"; do
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local et; et="$(awk '{print $2}' <<<"$line")"
            [ -z "$et" ] && continue
            if [ "$et" -gt $((prog * 60)) ]; then
                out+="$line"$'\n'; n=$((n+1))
            fi
        done < <(ps -eo pid=,etimes=,args= 2>/dev/null | grep -F -- "$p" | grep -v grep | grep -v build-placement)
    done
    printf '%s\t%b' "$n" "$out"
}

if [ "$SELFTEST" = "1" ]; then
    # proces-dowód: argv zawiera „cargo build”, żyje dłużej niż próg 0 min
    ( exec -a 'cargo build --release -p dowod-ze-bramka-gryzie' sleep 25 ) &
    FPID=$!
    sleep 1
    RES="$(scan 0)"; N="${RES%%$'\t'*}"
    kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null
    if [ "${N:-0}" -ge 1 ]; then
        echo "build-placement selftest: PASS (wykryto proces budujący: ${N})"
        exit 0
    fi
    echo "build-placement selftest: FAIL — bramka NIE wykrywa procesu budującego (martwy warunek)"
    exit 1
fi

case ",${WAZNE}," in
    *",${HOST},"*) ;;
    *) echo "build-placement: PASS — host ${HOST} nie jest stanowiskiem pracy (buduje gdzie indziej)"; exit 0 ;;
esac

RES="$(scan "$PROG_MIN" 2>/dev/null)" || { echo "build-placement: UNKNOWN — nie mogę odczytać listy procesów"; exit 2; }
N="${RES%%$'\t'*}"; LINES="${RES#*$'\t'}"

if [ "${N:-0}" -gt 0 ]; then
    echo "build-placement: FAIL (LAW-BUILD-PLACEMENT-1) — ${N} build(ów) >${PROG_MIN} min na ${HOST}:"
    printf '%s' "$LINES" | sed 's/^/  /' | cut -c1-150
    echo "  → kanoniczna droga: scripts/build-runtime-remote.sh (builder VM 110, ~12 min) lub HPC"
    exit 1
fi

echo "build-placement: PASS (LAW-BUILD-PLACEMENT-1) — 0 długich buildów na ${HOST}"
exit 0
