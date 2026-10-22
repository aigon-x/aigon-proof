#!/usr/bin/env bash
# kernel-observability.sh — GATE: każdy kernel MUSI raportować braki (nie cisza).
# Kontrakt hook-runner: tools/gates/<id>.sh, exit 0=PASS 1=FAIL 2=env.
#
# ROZKAZ SUWERENA 2026-10-02: „rakieta nie reaguje, wkurwia mnie że to nic nie
# reaguje — może powinien być kernelem?". Zmierzona luka: kernel BEZ mechanizmu
# raportowania może mieć realne braki funkcjonalne, których NIKT NIE MIERZY —
# raportuje „Healthy", bo nie ma czym zgłosić problemu (fałszywy zielony).
# Zmierzone 2026-10-02: mechanizm `bramkarz` (raport „co nie działa") miał
# TYLKO 1/39 kerneli; `deadman` (wykrywanie martwego komponentu) 4/33 crate.
#
# Brzmienie wymagania: kernel, który wykonuje pracę zależną od ZEWNĘTRZNYCH
# elementów (crony, workflowy, DB, HPC, SSH) MUSI mieć mechanizm wykrywania
# braku sygnału (deadman/mtime) albo licznik błędów odczytu — inaczej awaria
# jest cicha.
#
# Kryterium PASS dla kernela: jego crate zawiera JEDNO z:
#   - `deadman`/`expired`/`mtime` — wykrywanie braku świeżego sygnału,
#   - `_read_errors`/`read_failures`/`error_count` — licznik błędów źródła,
#   - `defekty`/`bramkarz`/`issues` — jawna lista braków.
# Kerneli bez żadnego z tych = FAIL (nie mają jak zgłosić braku).
# Wyjątki (kerneli czysto-obliczeniowych bez zewnętrznego źródła) w
# tools/gates/kernel-observability-allowlist.txt — każde z uzasadnieniem.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATES_DIR="$ROOT/runtime/crates"
ALLOW="$ROOT/tools/gates/kernel-observability-allowlist.txt"

[ -d "$CRATES_DIR" ] || { echo "kernel-observability: SKIP — brak $CRATES_DIR (env)"; exit 2; }

RES=$(python3 - "$ROOT" <<'__PYKOBS__'
import sys, os, glob, re

root = sys.argv[1]
# Sygnały raportowania braków (co najmniej jeden = kernel ma JAK zgłosić brak).
SIGNALS = ("deadman", "expired(", "read_errors", "read_failures",
           "scan_errors", "error_count", "errors_total", "defekty",
           "bramkarz", "issues.push")
# Sygnały ZEWNĘTRZNEGO ŹRÓDŁA (kernel zależy od czegoś poza procesem: DB, HTTP,
# SSH, cron, subprocess, SIEĆ). TYLKO taki kernel MUSI mieć mechanizm raportowania
# — bez źródła nie ma czego „deadmanować". UWAGA: lokalny std::fs::read własnego
# pliku konfiguracji NIE jest źródłem zewnętrznym (fałszywe trafienie: hawking).
EXTERNAL = ("subprocess", "Command::new(", "reqwest", "sqlx", "psql",
            "TcpStream", "ssh ", "connect_timeout", "UdpSocket", "postgres")
fail, ok, skip = [], [], []
for d in sorted(glob.glob(os.path.join(root, "runtime/crates/aigon-kernel-*/"))):
    name = os.path.basename(d.rstrip("/")).replace("aigon-kernel-", "")
    src = ""
    for f in glob.glob(d + "src/**/*.rs", recursive=True):
        try:
            src += open(f).read()
        except OSError:
            pass
    if not src:
        continue
    has_ext = any(s in src for s in EXTERNAL)
    has_sig = any(s in src for s in SIGNALS)
    if not has_ext:
        skip.append(name)          # czysto-obliczeniowy — nie wymaga raportowania
    elif has_sig:
        ok.append(name)            # ma źródło zewnętrzne + mechanizm raportowania
    else:
        fail.append(name)          # MA źródło, ale nie ma jak zgłosić braku
print("OK:" + ",".join(ok))
print("FAIL:" + ",".join(fail))
print("SKIP:" + ",".join(skip))
__PYKOBS__
)

OK=$(printf '%s\n' "$RES" | grep '^OK:' | cut -d: -f2-)
FAILLIST=$(printf '%s\n' "$RES" | grep '^FAIL:' | cut -d: -f2-)

# Allowlist (kerneli czysto-obliczeniowe — znany dług, wolno tylko zmniejszać)
if [ -f "$ALLOW" ] && [ -n "$FAILLIST" ]; then
  FAILLIST=$(printf '%s' "$FAILLIST" | tr ',' '\n' \
             | grep -vxF -f <(grep -vE '^\s*#|^\s*$' "$ALLOW") | paste -sd, - || true)
fi

N_OK=$(printf '%s' "$OK" | tr ',' '\n' | grep -c . || true)
N_FAIL=$(printf '%s' "$FAILLIST" | tr ',' '\n' | grep -c . || true)

if [ "$N_FAIL" -eq 0 ]; then
  echo "kernel-observability: PASS — każdy z $N_OK kerneli ma mechanizm raportowania braków (deadman/licznik/lista)"
  exit 0
fi

echo "kernel-observability: FAIL — $N_FAIL kerneli NIE MA jak zgłosić braku (cisza = fałszywy zielony):"
printf '%s' "$FAILLIST" | tr ',' '\n' | grep . | sed 's/^/  /'
echo "  Wymóg: kernel z zewnętrznym źródłem (cron/workflow/DB/HPC) MUSI mieć deadman|read_errors|defekty|issues."
echo "  Kernel czysto-obliczeniowy dopisz do tools/gates/kernel-observability-allowlist.txt z uzasadnieniem."
exit 1
