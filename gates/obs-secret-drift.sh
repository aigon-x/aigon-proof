#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  obs-secret-drift.sh — bramka triggera runtime:secret-drift
#
#  Kontrakt bramki (hook-runner.sh): 0=PASS, 1=FAIL, 2=WARN.
#
#  Wykrywa i NATYCHMIAST naprawia drift plikow credentials_file Prometheusa.
#  Dlaczego bramka, a nie tylko watcher: bramka jest wolana przez hook-runner
#  (trigger runtime:secret-drift), wiec kazda reakcja zostawia SLAD DOWODOWY
#  (evidence POST do runtime) — incydent jest rejestrowany, nie tylko "cicho
#  naprawiony". Dodatkowo bramka dziala standalone (recznie / z innego triggera).
#
#  Incydent 2026-09-21: aito-api-key byl pustym KATALOGIEM -> Prometheus nie
#  mogl odczytac klucza (job = failed scrape) przy ZUPELNIE DOBRYM kluczu API.
#  Monitoring slepnie bez czerwonego swiatla.
#
#  ROZSZERZENIE 2026-09-30 (klasa FALSZYWY-ZIELONY):
#  Incydent: destination mountu w docker-compose.yml byl zamaskowany do
#  "/etc/p...y" zamiast "/etc/prometheus/qdrant-api-key" (regresja commitu
#  11db9567 maskujacego sciezki). Plik na dysku byl CALY CZAS poprawny, wiec
#  STARA bramka (patrzyla WYLACZNIE na host) zwracala exit 0 — a Prometheus
#  nie mogl odczytac klucza: 5 targetow aigon-qdrant DOWN.
#  Bramka sprawdza teraz TRZY warstwy (defense in depth):
#    A) destination mountu w docker-compose.yml — maskowanie ("...") / uciecie
#       koncowej nazwy pliku (statyczna, dziala nawet bez kontenera);
#    B) obecnosc KAZDEJ wymaganej sciezki W KONTENERZE — `promtool check
#       config` (autorytatywny: raportuje brak credentials_file) + `test -e`
#       per sciezka (dokladny komunikat ktorej sciezki brakuje);
#    C) pliki na hoscie (jak dotad: regularne, niepuste).
#
#  Kanaly testowe (env, bez dotykania produkcji):
#    COMPOSE_FILE=<plik>   PROM_YML=<plik>   PROM_CTR=<nazwa>
#    GATE_NO_REPAIR=1      (tylko wykrywaj — NIE wolaj watchdoga/recreate)
#    GATE_SKIP_COMPOSE=1   GATE_SKIP_CTR=1   (izolacja warstw w testach)
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WATCHDOG="$ROOT/scripts/observability-secret-watchdog.sh"
PROM_DIR="${PROM_DIR:-$ROOT/observability/prometheus}"
PROM_YML="${PROM_YML:-$PROM_DIR/prometheus.yml}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT/docker-compose.yml}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-prometheus}"
PROM_CTR="${PROM_CTR:-aigon-observability-prometheus}"
PROM_CTR_YML="${PROM_CTR_YML:-/etc/prometheus/prometheus.yml}"
GATE_NO_REPAIR="${GATE_NO_REPAIR:-0}"     # 1 = wykrywaj, nie naprawiaj (testy)
GATE_SKIP_COMPOSE="${GATE_SKIP_COMPOSE:-0}"
GATE_SKIP_CTR="${GATE_SKIP_CTR:-0}"

echo "obs-secret-drift: warstwa 1/3 compose · 2/3 kontener · 3/3 host"

COMPOSE_DEFECT=0
CTR_DEFECT=0
HOST_DEFECT=0

# ── Wymagane sciezki IN-KONTENER z prometheus.yml ────────────────────────
# Zrodlo prawdy: sam prometheus.yml. credentials_file/bearer_token_file/
# password_file oraz file_sd (katalog) i rule_files. Nie hardkodujemy listy —
# nowy job z nowym credentials_file jest sprawdzany automatycznie.
required_paths() {
  python3 - "$PROM_YML" <<'PY'
import sys, yaml, posixpath
try:
    with open(sys.argv[1]) as fh:
        d = yaml.safe_load(fh) or {}
except Exception as e:  # noqa: BLE001
    sys.stderr.write("parse-error: %s\n" % e)
    sys.exit(3)

seen = set()
def emit(p, kind):
    if not isinstance(p, str) or not p.startswith("/"):
        return
    if p in seen:
        return
    seen.add(p)
    print("%s\t%s" % (kind, p))

FILE_KEYS = ("credentials_file", "bearer_token_file", "password_file")
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in FILE_KEYS and isinstance(v, str):
                emit(v, k)
            if k == "files" and isinstance(v, list):
                for it in v:
                    if isinstance(it, str) and it.startswith("/"):
                        # file_sd: pilnujemy KATALOGU (pliki generuje per-node
                        # cron; brak konkretnego pliku != awaria transportu)
                        emit(posixpath.dirname(it) or "/", "file_sd_dir")
            walk(v)
    elif isinstance(node, list):
        for it in node:
            walk(it)

for rf in (d.get("rule_files") or []):
    emit(rf, "rule_files")
walk(d.get("scrape_configs"))
walk(d.get("remote_write"))
walk(d.get("remote_read"))
walk(d.get("alerting"))
PY
}

REQ_LIST=""
if ! REQ_LIST=$(required_paths); then
  echo "  DEFECT: nie moge odczytac wymaganych sciezek z $PROM_YML"
  echo "FAIL: prometheus.yml nieparsowalny — nie wiem czego pilnowac"
  exit 1
fi
REQ_COUNT=$(printf '%s\n' "$REQ_LIST" | grep -c . || true)
echo "  wymagane sciezki in-kontener: $REQ_COUNT"

# ── Warstwa A: destination mountu w compose (maskowanie/uciecie) ─────────
check_compose() {
  if [ "$GATE_SKIP_COMPOSE" = "1" ]; then
    echo "  [A] compose: POMINIETY (GATE_SKIP_COMPOSE=1)"; return 0
  fi
  if [ ! -r "$COMPOSE_FILE" ]; then
    echo "  [A] DEFECT: brak czytelnego $COMPOSE_FILE"; COMPOSE_DEFECT=1; return 0
  fi
  # src<TAB>dst dla wolumenow bind serwisu prometheus
  local pairs
  pairs=$(python3 - "$COMPOSE_FILE" "$COMPOSE_SERVICE" <<'PY'
import sys, yaml
try:
    with open(sys.argv[1]) as fh:
        d = yaml.safe_load(fh) or {}
except Exception as e:  # noqa: BLE001
    sys.stderr.write("parse-error: %s\n" % e); sys.exit(3)
svc = (d.get("services") or {}).get(sys.argv[2]) or {}
for v in (svc.get("volumes") or []):
    if not isinstance(v, str):
        sys.stderr.write("skip-non-string-volume\n"); continue
    parts = v.split(":")
    if len(parts) < 2:
        continue
    print("%s\t%s" % (parts[0], parts[1]))
PY
) || { echo "  [A] DEFECT: nie moge sparsowac $COMPOSE_FILE"; COMPOSE_DEFECT=1; return 0; }

  declare -A DSTS=()
  local line src dst base
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    src="${line%%$'\t'*}"; dst="${line#*$'\t'}"
    DSTS["$dst"]=1
    # sygnatura defektu: maskowanie trojkapunktem
    case "$dst" in
      *...*) echo "  [A] DEFECT: destination zamaskowany '...': $dst (src=$src)"
             COMPOSE_DEFECT=1 ;;
    esac
    # destination pod /etc/prometheus MUSI konczyc sie nazwa zrodla (basename)
    if [ -n "$src" ] && [ "${src#/}" != "$src" ]; then
      base="${src##*/}"
      case "$dst" in
        /etc/prometheus/*) case "$dst" in
            */"$base") : ;;  # zgodne
            *) echo "  [A] DEFECT: destination uciety: '$dst' != '.../$base' (src=$src)"
               COMPOSE_DEFECT=1 ;;
          esac ;;
      esac
    fi
  done <<< "$pairs"

  # kazda wymagana sciezka MUSI miec mount destination (dokladne dopasowanie)
  local kind p
  while IFS=$'\t' read -r kind p; do
    [ -n "$p" ] || continue
    if [ "${DSTS[$p]:-}" != "1" ]; then
      echo "  [A] DEFECT: brak mountu destination=$p (wymagane przez $kind)"
      COMPOSE_DEFECT=1
    fi
  done <<< "$REQ_LIST"

  [ "$COMPOSE_DEFECT" -eq 0 ] && echo "  [A] compose: destination mountow zgodne ze zrodlem i prometheus.yml"
  return 0
}

# ── Warstwa B: obecnosc sciezek w kontenerze ─────────────────────────────
check_container() {
  if [ "$GATE_SKIP_CTR" = "1" ]; then
    echo "  [B] kontener: POMINIETY (GATE_SKIP_CTR=1)"; return 0
  fi
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PROM_CTR"; then
    echo "  [B] kontener $PROM_CTR nie dziala — pomijam (stack-health-check go podniesie)"
    return 0
  fi

  # promtool — autorytatywny: raportuje brak credentials_file (zweryfikowane
  # 2026-09-30: 'FAILED: error checking authorization credentials ... no such file')
  local out
  out=$(docker exec "$PROM_CTR" promtool check config "$PROM_CTR_YML" 2>&1)
  if [ $? -ne 0 ]; then
    echo "  [B] DEFECT promtool: $(printf '%s\n' "$out" | grep -iE 'FAILED|error' | head -2 | tr '\n' ' ')"
    CTR_DEFECT=1
  else
    echo "  [B] promtool: SUCCESS ($PROM_CTR_YML)"
  fi

  # test -e per sciezka — precyzyjny komunikat KTOREJ sciezki brakuje
  local kind p
  while IFS=$'\t' read -r kind p; do
    [ -n "$p" ] || continue
    if ! docker exec "$PROM_CTR" test -e "$p" 2>/dev/null; then
      echo "  [B] DEFECT: $p MISSING w kontenerze (wymagane przez $kind)"
      CTR_DEFECT=1
    fi
  done <<< "$REQ_LIST"
  return 0
}

# ── Warstwa C: pliki na hoscie (regulne, niepuste) ───────────────────────
check_host() {
  local f p
  for f in aito-api-key qdrant-api-key router-api-key; do
    p="$PROM_DIR/$f"
    if   [ ! -e "$p" ]; then echo "  [C] DEFECT $f: MISSING";   HOST_DEFECT=1
    elif [ -d "$p" ];    then echo "  [C] DEFECT $f: DIRECTORY"; HOST_DEFECT=1
    elif [ ! -s "$p" ];  then echo "  [C] DEFECT $f: EMPTY";     HOST_DEFECT=1
    fi
  done
  [ "$HOST_DEFECT" -eq 0 ] && echo "  [C] host: aito/qdrant/router — regularne, niepuste pliki"
  return 0
}

check_compose
check_container
check_host

# ── Werdykt ──────────────────────────────────────────────────────────────
# Defekt compose (zamaskowana/ucieta sciezka) NIE jest naprawialny przez
# watchdoga — to blad konfiguracji, wymaga czlowieka. FAIL glosno, bez proby
# cichej "naprawy", ktora i tak nie zmieni mountu.
if [ "$COMPOSE_DEFECT" -ne 0 ]; then
  echo "FAIL: defekt docker-compose.yml (maskowanie/uciecie destination mountu) — popraw konfiguracje; auto-naprawa nie dotyczy configu"
  exit 1
fi

if [ "$CTR_DEFECT" -eq 0 ] && [ "$HOST_DEFECT" -eq 0 ]; then
  echo "PASS: compose OK + sciezki w kontenerze OK + pliki na hoscie OK"
  exit 0
fi

# ── Auto-naprawa (jedno zrodlo prawdy: SSOT /opt/PROD/.env + recreate) ──
if [ "$GATE_NO_REPAIR" = "1" ]; then
  echo "FAIL: wykryto drift (host=$HOST_DEFECT ctr=$CTR_DEFECT); auto-naprawa wylaczona (GATE_NO_REPAIR=1)"
  exit 1
fi
if [ ! -e "$WATCHDOG" ]; then
  echo "FAIL: brak $WATCHDOG — nie moge naprawic automatycznie"
  exit 1
fi
echo "  naprawiam: bash $WATCHDOG"
bash "$WATCHDOG" || { echo "FAIL: auto-naprawa nie powiodla sie"; exit 1; }

# ── Weryfikacja PO naprawie (bez tego "naprawione" bylo by deklaracja) ──
CTR_DEFECT=0; HOST_DEFECT=0
check_container
check_host
if [ "$CTR_DEFECT" -ne 0 ] || [ "$HOST_DEFECT" -ne 0 ]; then
  echo "FAIL: drift nadal obecny po naprawie (host=$HOST_DEFECT ctr=$CTR_DEFECT)"
  exit 1
fi
echo "PASS: naprawione i zweryfikowane — incydent zarejestrowany w evidence"
exit 0
