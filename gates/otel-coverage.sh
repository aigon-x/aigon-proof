#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/otel-coverage.sh — gate OTEL-COVERAGE
#
#  PO CO (pytanie Suwerena 2026-09-29: „no a czemu tego nie ma w otelu i
#  tempo i czemu nikt tego nie naprawił; wszystko ma być kanonicznie"):
#    ZMIERZONE — domena `snappymail*` miała w Prometheusie **0 metryk**
#    (webmail mail.szamani.ai nie istniał w żadnym dashboardzie ani trace),
#    a w Tempo ostatnie 50 trace to wyłącznie `aigon-runtime`. System miał
#    usługi CAŁKOWICIE niewidoczne dla obserwowalności i **żadna brama tego
#    nie zgłaszała** — liveness (`container_up`) != obserwowalność.
#
#  CO MIERZY:
#    Każda usługa z docker-compose.yml musi mieć ODPOWIEDNIK w
#    observability/prometheus/prometheus.yml (job o dopasowanej nazwie).
#    Bez tego metryki usługi nie istnieją — nie ma dashboardu, nie ma alertu,
#    a `up{}` o niej nie wie.
#
#  RATCHET (klucz projektu — dług można TYLKO zmniejszać):
#    Lista znanych braków jest w config/canonical/otel-coverage-debt.txt.
#    - brak SPOZA listy            -> FAIL (nowa usługa bez telemetrii)
#    - wpis na liście, który JUŻ MA job -> FAIL (dług spłacony, usuń wpis)
#    Dzięki temu brama nie blokuje na zastanym, ale nie pozwala go zwiększyć
#    ANI udawać, że nadal istnieje po naprawie.
#
#  KONTRAKT: exit 0 = PASS, exit 1 = FAIL.
#  Env: AIGON_OTEL_DEBT (ścieżka listy długu).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"
PROM="$ROOT/observability/prometheus/prometheus.yml"
DEBT="${AIGON_OTEL_DEBT:-$ROOT/config/canonical/otel-coverage-debt.txt}"
export PATH="/usr/bin:/usr/local/bin:$PATH"

fails=0
say() { printf '       %s\n' "$*"; }

for f in "$COMPOSE" "$PROM"; do
  if [ ! -f "$f" ]; then
    say "FAIL: brak $f"
    echo "otel-coverage: FAIL (brak pliku wejściowego)"
    exit 1
  fi
done

# Usługi compose (poziom 2 spacji w sekcji services) vs joby Prometheusa.
report="$(python3 - "$COMPOSE" "$PROM" "$DEBT" <<'PY'
import re, sys, os

compose_path, prom_path, debt_path = sys.argv[1:4]
compose = open(compose_path, encoding="utf-8", errors="replace").read()
m = re.search(r'^services:\n((?:.|\n)*?)^[a-z]', compose, re.M)
body = m.group(1) if m else compose
# Pomijamy klucze nienależące do usług (volumes/networks/secrets) ORAZ
# WPISY-WOLUMENY: compose deklaruje volume o tej samej nazwie co usługa
# (`snappymail-data`, `rachet-data`, `observatory-data`), a to NIE są usługi
# — nie mogą mieć joba. Filtr: sufiks `-data`/`_data`, nazwy infrastruktury
# trzymające stan (`cron-host`, `environment`, `promtail-positions`,
# `vault-logs`) oraz samo `mail-*-data`. Bez tego detektor raportuje konstrukcje
# YAML jako brakującą telemetrię (fałszywy FAIL — klasa: detektor patrzy na
# niewłaściwą rzecz).
svcs = set(re.findall(r'^  ([a-z][a-z0-9_-]*):$', body, re.M))
_NON_SERVICE = {"volumes", "networks", "secrets", "configs", "services",
                "cron-host", "environment", "promtail-positions", "vault-logs"}
svcs = {s for s in svcs
        if not s.endswith(("-data", "_data"))
        and s not in _NON_SERVICE}

prom = open(prom_path, encoding="utf-8", errors="replace").read()
jobs = set(re.findall(r'job_name:\s*"?([a-z0-9_.-]+)"?', prom))

debt = set()
if os.path.exists(debt_path):
    for ln in open(debt_path, encoding="utf-8", errors="replace"):
        ln = ln.split("#", 1)[0].strip()
        if ln:
            debt.add(ln)

def covered(s):
    return s in jobs or any(s in j or j in s for j in jobs)

missing = sorted(s for s in svcs if not covered(s))
new      = sorted(s for s in missing if s not in debt)
repaid   = sorted(s for s in debt if s and covered(s))

print(f"USLUG={len(svcs)} JOBOW={len(jobs)} BRAK={len(missing)} NOWE={len(new)} SPLACONE={len(repaid)}")
print("NOWE:");      [print(f"  {s}") for s in new[:40]]
print("SPLACONE:");  [print(f"  {s}") for s in repaid[:40]]
PY
)"

summary="$(printf '%s\n' "$report" | head -1)"
usl=$(printf '%s' "$summary" | sed -n 's/.*USLUG=\([0-9]*\).*/\1/p')
brak=$(printf '%s' "$summary" | sed -n 's/.*BRAK=\([0-9]*\).*/\1/p')
nowe=$(printf '%s' "$summary" | sed -n 's/.*NOWE=\([0-9]*\).*/\1/p')
splac=$(printf '%s' "$summary" | sed -n 's/.*SPLACONE=\([0-9]*\).*/\1/p')

say "usług: ${usl:-?}, bez joba: ${brak:-?}, nowych: ${nowe:-?}, spłaconych wpisów długu: ${splac:-?}"

if [ "${nowe:-0}" -gt 0 ]; then
  say "FAIL: ${nowe} usług BEZ telemetrii (nie ma ich na liście długu):"
  printf '%s\n' "$report" | sed -n '/^NOWE:/,/^SPLACONE:/p' | grep '^  ' | head -12
  say "      Naprawa: dodaj job do $PROM albo (świadomie) wpis do $DEBT"
  fails=$((fails+1))
fi

if [ "${splac:-0}" -gt 0 ]; then
  say "FAIL: ${splac} wpisów długu ma JUŻ job — spłacone, usuń z $DEBT (ratchet: dług tylko maleje)"
  printf '%s\n' "$report" | sed -n '/^SPLACONE:/,$p' | grep '^  ' | head -12
  fails=$((fails+1))
fi

# ── SEKCJA 2: komponenty spoza compose (cron: pipeline'y, bramki) ────────
# Usługi compose to nie wszystko: pipeline'y i bramki biegają z crona, a ich
# brak spanu nie był przez nikogo wykrywany (luka zmierzona 2026-09-30 —
# jedyne spany leonardo.* w Tempo to exporter.run i cert.renew). Rejestr
# `config/canonical/otel-span-registry.txt` domyka ją jawnie:
# `<ścieżka>|<marker>` — plik MUSI istnieć i zawierać emiter spanu.
REG="${AIGON_OTEL_SPAN_REGISTRY:-$ROOT/config/canonical/otel-span-registry.txt}"
if [ -r "$REG" ]; then
  span_missing=(); span_nofile=(); span_checked=0
  while IFS='|' read -r spath smarker; do
    spath="${spath%%#*}"; spath="$(printf '%s' "$spath" | tr -d '[:space:]')"
    [ -n "$spath" ] || continue
    smarker="${smarker# }"; smarker="${smarker% }"
    [ -n "$smarker" ] || smarker="otel_span_emit"
    full="$spath"; [ "${spath#/}" = "$spath" ] && full="$ROOT/$spath"
    span_checked=$((span_checked+1))
    if [ ! -f "$full" ]; then span_nofile+=("$spath"); continue; fi
    grep -q "$smarker" "$full" 2>/dev/null || span_missing+=("$spath")
  done < "$REG"
  say "spany (rejestr): sprawdzono ${span_checked}, bez pliku: ${#span_nofile[@]}, bez emisji: ${#span_missing[@]}"
  if [ "${#span_nofile[@]}" -gt 0 ]; then
    say "FAIL: rejestr spanów wskazuje nieistniejące pliki: ${span_nofile[*]}"
    fails=$((fails+1))
  fi
  if [ "${#span_missing[@]}" -gt 0 ]; then
    say "FAIL: komponenty bez emisji spanu OTEL: ${span_missing[*]}"
    fails=$((fails+1))
  fi
fi

if [ "$fails" -eq 0 ]; then
  echo "otel-coverage: PASS (każda usługa ma job albo świadomy wpis długu)"
  exit 0
fi
echo "otel-coverage: FAIL (${fails} asercji)"
exit 1
