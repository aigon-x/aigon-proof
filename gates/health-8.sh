#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/health-8.sh — gate health-8 (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Quorum zdrowia: /health 200 na kazdym z nodow mesha (ssh sweep
#  wg config/mesh-nodes.yaml). Node bez ssh (lub local) testowany
#  bezposrednio na RUNTIME_URL.
#
#  Kontrakt: exit 0 = PASS (kworum liczonych nodów 200), exit 1 = FAIL (brak kworum).
#  Zmienne env: AIGON_RUNTIME_URL, AIGON_HEALTH8_SKIP_SSH=1 (testy),
#               AIGON_HEALTH8_WAIT_SECS (domyslnie 240),
#               AIGON_HEALTH8_RETRY_EVERY (domyslnie 15).
#
#  POPRAWKA 2026-10-11 (LAW-22, pomiar nie lagodzenie):
#    Bramka wymuszala JEDNOMYSLNOSC (kazdy liczony node 200), a LAW-22 mowi
#    wprost o KWORUM ("Decyzje o stanie globalnym wymagaja kworum. Brak kworum =
#    brak zapisu"). To mierzenie NIE TEGO, co wymaga prawo (probe-target-mismatch):
#    zmierzone 2026-10-11 — runtime raportowal mesh.has_quorum=true (7/8 Healthy,
#    poligon state=Unreachable od 8 dni), a brama FAILowala, bo chciala 8/8.
#    Teraz werdykt = kworum: wiekszosc liczonych nodow (bez expected_down) musi
#    odpowiadac 200; liczba zdrowych/oczekiwanych jest raportowana wprost (brak
#    ukrywania ubytku). Nieobecnosc noda jest widoczna w mesh-presence (LAW-29).
#    Fast-path bez zmian: gdy WSZYSTKIE liczone nody sa 200 -> natychmiast PASS.
#
#  DWIE POPRAWKI 2026-09-23 — obie o POMIARZE, nie o lagodzeniu progu:
#  1) Bounded retry. Gate chodzi m.in. w triggerze runtime:deploy ZARAZ po
#     `compose recreate`, a odtworzony runtime startuje minuty (boot-tick
#     trzyma write lock; zmierzone 2-9 min). Jedna proba w tej samej
#     sekundzie dawala FALSZYWY FAIL: "FAIL (chore: 192.0.2.18=000)"
#     ~3 s po recreate, gdy ten sam node odpowiadal 200 dwie minuty pozniej.
#     Teraz: ponawianie do WAIT_SECS, werdykt z podaniem czasu.
#  2) Honoring expected_down. Poprzednia wersja czytala WSZYSTKIE `ip:`
#     z mesh-nodes.yaml, wiec nody swiadomie wylaczone (site/optiq/mail,
#     `expected_down: true`) obciazaly werdykt — wbrew kanonowi, ktory
#     ci-deploy i mesh_exec juz respektuja.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_URL="${AIGON_RUNTIME_URL:-https://127.0.0.1:7000}"
WAIT_SECS="${AIGON_HEALTH8_WAIT_SECS:-240}"
RETRY_EVERY="${AIGON_HEALTH8_RETRY_EVERY:-15}"

# ip ssh expected_down — jeden wiersz na node (blok: od `ip:` do nastepnego `ip:`)
nodes_tsv() {
  awk '
    /^[[:space:]]+ip:[[:space:]]/ { if (ip != "") print ip "|" ssh "|" ed; ip=$2; ssh=""; ed="false"; next }
    /^[[:space:]]+ssh:[[:space:]]/ { v=$2; if (v != "null") ssh=v; next }
    /^[[:space:]]+expected_down:[[:space:]]*true/ { ed="true"; next }
    END { if (ip != "") print ip "|" ssh "|" ed }
  ' "$ROOT/config/mesh-nodes.yaml"
}

probe() { # <ip> <ssh> -> kod HTTP
  local ip="$1" sshh="$2"
  if [ "${AIGON_HEALTH8_SKIP_SSH:-0}" = "1" ] || [ -z "$sshh" ]; then
    curl -sk -m 6 "$RUNTIME_URL/health" -o /dev/null -w "%{http_code}" 2>/dev/null
  else
    # SSH must not consume nodes_tsv on stdin: without -n, the first remote
    # probe can drain the loop input and falsely report only LOCAL+one peer.
    timeout 10 ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$sshh" \
      'curl -sk -m 5 https://127.0.0.1:7000/health -o /dev/null -w "%{http_code}"' 2>/dev/null
  fi
}

started=$(date +%s)
deadline=$(( started + WAIT_SECS ))
QUORUM=0
while :; do
  BAD=""; CHECKED=0; HEALTHY=0
  while IFS='|' read -r ip sshh ed; do
    [ -n "$ip" ] || continue
    [ "$ed" = "true" ] && continue        # expected_down: swiadomie wylaczony, nie liczymy
    CHECKED=$(( CHECKED + 1 ))
    H=$(probe "$ip" "$sshh")
    if [ "$H" = "200" ]; then HEALTHY=$(( HEALTHY + 1 )); else BAD="$BAD $ip=${H:-000}"; fi
  done < <(nodes_tsv)

  if [ "$CHECKED" -eq 0 ]; then
    echo "health-8: FAIL (rejestr mesh-nodes.yaml nie dal zadnego node'a — sprawdz plik)"
    exit 1
  fi
  # KWORUM (LAW-22), nie jednomyslnosc: wiekszosc liczonych nodow musi byc 200.
  QUORUM=$(( CHECKED / 2 + 1 ))
  if [ "$HEALTHY" -ge "$QUORUM" ]; then
    echo "health-8: PASS ($HEALTHY/$CHECKED >= kworum $QUORUM, po $(( $(date +%s) - started ))s${BAD:+; chore:$BAD})"
    exit 0
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep "$RETRY_EVERY"
done

echo "health-8: FAIL (kworum ${HEALTHY:-0}/${CHECKED:-0} < wymagane ${QUORUM:-?}; chore:$BAD) — po $(( $(date +%s) - started ))s ponawiania (WAIT_SECS=$WAIT_SECS)"
exit 1
