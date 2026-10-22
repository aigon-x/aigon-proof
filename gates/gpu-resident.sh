#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/gpu-resident.sh — GATE (cheker): rezydent GPU na karcie
#
#  NAPRAWA 2026-10-03 (defekt GPU: rezydent gpt-oss-20b przeładowywany co
#  ~10 min, VRAM skakał 13GB<->1GB). Ta bramka czyta JEDNĄ metrykę prawdy
#  `aigon_gpu_resident_model_loaded` (producent:
#  scripts/aigon-gpu-resident-check.py, pomiar z nvidia-smi — NIE z /api/ps,
#  które kłamie w dół: models:[] przy VRAM=12292 MiB).
#
#  Kontrakt hook-runner: exit 0=PASS 1=FAIL 2=env (WARN).
#    * brak nvidia-smi / brak metryki  -> 2 (brak pomiaru != FAIL; deadman
#      pilnuje samego braku pomiaru w Prometheusie).
#    * aigon_gpu_resident_model_loaded == 1 -> 0 PASS
#    * aigon_gpu_resident_model_loaded == 0 -> 1 FAIL (kanon "GPU = 1 model")
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

PROM="${AIGON_GPU_RESIDENT_PROM:-/var/lib/node_exporter/textfile_collector/aigon-gpu-resident.prom}"

command -v nvidia-smi >/dev/null 2>&1 || { echo "gpu-resident: SKIP — brak nvidia-smi (env)"; exit 2; }
[ -r "$PROM" ] || { echo "gpu-resident: WARN — brak metryki $PROM (brak pomiaru != zero)"; exit 2; }

LOADED=$(awk '/^aigon_gpu_resident_model_loaded /{print $2}' "$PROM" | tail -1)
VRAM=$(awk '/^aigon_gpu_resident_vram_mib /{print $2}' "$PROM" | tail -1)

# ŚWIEŻOŚĆ POMIARU (LAW-HEALTH-1, dopisane 2026-10-19): eksporter chodzi z crona
# co 5 min, więc plik bywa nieaktualny. Zmierzone: VRAM realnie 963 MiB (model
# wyładowany), a bramka czytała 13620 MiB z pliku sprzed minut → FAŁSZYWY
# ZIELONY; po restarcie ollama odwrotnie — stara wartość dawała fałszywy PASS
# albo FAIL zależnie od momentu. Stary snapshot != zielony: >10 min = FAIL.
AGE=$(( $(date +%s) - $(stat -c %Y "$PROM" 2>/dev/null || echo 0) ))
if [ "$AGE" -gt 600 ]; then
  echo "gpu-resident: FAIL — metryka NIEŚWIEŻA (${AGE}s > 600s): $PROM"
  echo "  LAW-HEALTH-1: stary snapshot nie jest dowodem stanu. Sprawdz cron"
  echo "  aigon-gpu-resident-check (config/cron.yaml, '3-59/5 * * * *') i log"
  echo "  /var/log/aigon/gpu-resident.log"
  exit 1
fi

if [ -z "${LOADED:-}" ]; then
  echo "gpu-resident: WARN — metryka obecna, ale brak wartości (BRAK POMIARU)"; exit 2
fi

if [ "$LOADED" = "1" ]; then
  echo "gpu-resident: PASS — rezydent na karcie (VRAM=${VRAM:-?} MiB >= progu, pomiar ${AGE}s temu)"
  exit 0
fi

echo "gpu-resident: FAIL — BRAK rezydenta na GPU (VRAM=${VRAM:-?} MiB)."
echo "  Kanon 'GPU = DOKLADNIE 1 model rezydentny' zlamany."
echo "  Diagnoza: python3 /opt/PROD/scripts/aigon-gpu-resident-check.py --json"
echo "           journalctl -u ollama --since '20 min ago' | grep -E 'load_model|Load failed'"
echo "           tail /var/log/aigon/ollama-spin-guard.log"
exit 1
