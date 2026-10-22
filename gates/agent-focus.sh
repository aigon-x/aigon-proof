#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/agent-focus.sh — GATE LAW-FOCUS-1 (PRAWO FOKUSU)
#
#  KONTRAKT ZADEKLAROWANY W SSOT (config/canonical/agent-focus.yaml):
#    law:   LAW-FOCUS-1 — „Każdy agent ma swoje okno i swój fokus”
#    gate:  tools/gates/agent-focus.sh   (ten plik — wcześniej DEKLARACJA
#           BEZ IMPLEMENTACJI: law-gate-closure C7 wskazywał martwy egzekutor)
#
#  CO MIERZY (struktura, nie proza):
#    F1  SSOT agent-focus.yaml istnieje i parsuje się (YAML),
#    F2  w scan_paths NIE MA zakazanych komend kradnących fokus
#        (focus_commands_regex: xdotool windowactivate/windowfocus/key/type…,
#        wmctrl -a/-ia/-ir/-R), poza plikami z allowlisty (każdy wpis z reason),
#    F3  allowlist: każdy wpis ma `reason` (pusty wyjątek = nadużycie),
#    F4  allocator (scripts/agent-display.sh) istnieje i jest wykonywalny.
#
#  ZAKRES: 0 = PASS, 1 = FAIL, 2 = UNKNOWN (brak SSOT = nie udajemy zielonego).
#  --selftest: dowód negatywny — wstrzykuje zakazaną komendę do temp-pliku
#  i MUSI ją wykryć (bramka, która nie gryzie, nie istnieje).
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${AIGON_ROOT:-/srv/aigon}"
CFG="$ROOT/config/canonical/agent-focus.yaml"
SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

if [ ! -f "$CFG" ]; then
    echo "agent-focus: UNKNOWN — brak SSOT $CFG"
    exit 2
fi

# ── odczyt SSOT (Python, bo YAML + glob na scan_paths) ───────────────────
PARSED="$(python3 - "$CFG" <<'PY'
import sys, yaml, json
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
enf = (cfg.get("enforcement") or {})
out = {
    "law": enf.get("law"),
    "gate": enf.get("gate"),
    "regex": cfg.get("focus_commands_regex") or "",
    "paths": cfg.get("scan_paths") or [],
    "allow": [e.get("path") for e in (cfg.get("allowlist") or []) if isinstance(e, dict)],
    "allow_without_reason": [
        e.get("path") for e in (cfg.get("allowlist") or [])
        if isinstance(e, dict) and not str(e.get("reason") or "").strip()
    ],
    "allocator": cfg.get("allocator") or "",
}
print(json.dumps(out))
PY
)" || { echo "agent-focus: FAIL F1 — SSOT nieparsowalny ($CFG)"; exit 1; }

get() { printf '%s' "$PARSED" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))"; }

LAW="$(get law)"
REGEX="$(get regex)"
[ -n "$REGEX" ] || { echo "agent-focus: FAIL F1 — brak focus_commands_regex w SSOT"; exit 1; }

# ── Skan ─────────────────────────────────────────────────────────────────
scan() { # scan <extra-path|"">
    local extra="${1:-}" hits=0
    local -a paths
    mapfile -t paths < <(printf '%s' "$PARSED" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('\n'.join(d.get('paths') or []))")
    [ -n "$extra" ] && paths+=("$extra")
    for p in "${paths[@]}"; do
        [ -e "$p" ] || continue
        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            # allowlista: dopasowanie po ścieżce (dokładne lub prefiks katalogu)
            skip=0
            while IFS= read -r a; do
                [ -z "$a" ] && continue
                case "$hit" in "$a"|"$a"/*) skip=1; break;; esac
            done < <(printf '%s' "$PARSED" | python3 -c "
import json,sys
print('\n'.join(json.load(sys.stdin).get('allow') or []))")
            [ "$skip" = "1" ] && continue
            echo "  HIT: $hit"
            hits=$((hits+1))
        # Skanujemy TYLKO kod wykonywalny. Dokumentacja (.md) legalnie OPISUJE
        # komendy (np. skill ps5-remote-play-ops uczy xdotool) — prawo zakazuje
        # WYKONYWANIA komend kradnących fokus, nie ich opisywania.
        done < <(grep -rInP --include='*.sh' --include='*.bash' --include='*.py' \
                    --include='*.js' --include='*.ts' --include='*.jsx' --include='*.tsx' \
                    "$REGEX" "$p" 2>/dev/null | cut -d: -f1 | sort -u)
    done
    echo "$hits"
}

if [ "$SELFTEST" = "1" ]; then
    TMP="$(mktemp /tmp/agent-focus-selftest.XXXXXX.sh)"
    printf '#!/bin/bash\nxdotool windowactivate 1234\n' > "$TMP"
    N="$(scan "$TMP" | tail -1)"
    rm -f "$TMP"
    if [ "${N:-0}" -ge 1 ]; then
        echo "agent-focus selftest: PASS (wstrzyknięty xdotool windowactivate wykryty)"
        exit 0
    fi
    echo "agent-focus selftest: FAIL — bramka NIE wykrywa zakazanej komendy (martwy warunek)"
    exit 1
fi

OUT="$(scan "")"
N="$(printf '%s' "$OUT" | tail -1)"
HITS="$(printf '%s' "$OUT" | sed '$d')"

if [ -n "$HITS" ]; then
    echo "agent-focus: FAIL F2 — zakazane komendy kradnące fokus (${N}):"
    echo "$HITS"
    exit 1
fi

NOR="$(get allow_without_reason)"
if [ "$NOR" != "[]" ] && [ -n "$NOR" ]; then
    echo "agent-focus: FAIL F3 — allowlist bez uzasadnienia: $NOR"
    exit 1
fi

ALLOC="$(get allocator)"
if [ -n "$ALLOC" ] && [ ! -x "$ROOT/$ALLOC" ]; then
    echo "agent-focus: FAIL F4 — allocator $ALLOC nie istnieje lub nie jest wykonywalny"
    exit 1
fi

echo "agent-focus: PASS (${LAW:-LAW-FOCUS-1}) — 0 zakazanych komend w scan_paths; allocator OK"
exit 0
