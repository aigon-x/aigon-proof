#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/image-consistency.sh — gate image-consistency
#
#  Spójność obrazu runtime na 8 nodach (hooks.yaml: cyclic:daily).
#  Trzy poziomy weryfikacji — pierwszy dostępny wygrywa:
#    1. docker  → porównanie image ID kontenera aigon-core-runtime
#       z image: z docker-compose.yml (wersja wdrożona == deklarowana)
#    2. ssh     → sweep nodów z mesh-nodes.yaml: tag z .Config.Image ORAZ
#       digest warstw (RootFS.Layers) — treść, nie image ID (ID nie przeżywa
#       docker save/load, czyli ścieżki dystrybucji z ci-deploy.sh)
#    3. fallback (user aigon: bez docker/ssh) → /health :7000:
#       peer_count==8 && wszystkie state==Healthy = spójny mesh;
#       pełna weryfikacja obrazów i tak jest blokowana przy deploy
#       (runtime:deploy → image-id-vs-registry, wykonywany z rootem).
#  Fail-closed: mesh <8/8 lub rozjazd obrazów = FAIL (exit 1).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_URL="${AIGON_RUNTIME_URL:-https://127.0.0.1:7000}"
COMPOSE="$ROOT/docker-compose.yml"

# Referencja obrazu runtime'u z compose.
#
# KOREKTA 2026-08-26: było `grep '^\s*image:' | head -1`, czyli PIERWSZA
# linia `image:` w całym docker-compose.yml — a to `postgres:16-alpine`
# (linia 78). Poziom 1 porównywał więc kontener aigon-core-runtime z
# obrazem Postgresa i FAIL-ował codziennie od zawsze; przy
# `block_on_fail: false` w hooks.yaml (cyclic:daily) nikt tego nie czytał.
expected_image_ref() {
  grep -E '^\s*image:\s*\S*aigon-core-runtime:' "$COMPOSE" 2>/dev/null \
    | head -1 | sed -E 's/^\s*image:\s*//' | tr -d '"'"'"''
}

# ── Poziom 1: docker (root przy deploy / weryfikacja lokalna) ─────────
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  EXPECTED=$(expected_image_ref)
  [ -n "$EXPECTED" ] || { echo "FAIL image-consistency: brak image: w docker-compose.yml"; exit 1; }
  RUNNING=$(docker inspect --format '{{.Config.Image}}' aigon-core-runtime 2>/dev/null || echo "")
  if [ -n "$RUNNING" ] && [ "$RUNNING" = "$EXPECTED" ]; then
    echo "PASS image-consistency (docker): kontener=$RUNNING == compose=$EXPECTED"
    exit 0
  fi
  echo "FAIL image-consistency (docker): kontener='$RUNNING' != compose='$EXPECTED'"
  exit 1
fi

# ── Poziom 2: ssh sweep 8 nodów (root/sniegul z kluczami) ──────────────
if command -v ssh >/dev/null 2>&1; then
  EXPECTED=$(expected_image_ref)
  BAD=""; CHECKED=0; IDS=""
  while IFS= read -r line; do
    ip=$(echo "$line" | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$ip" ] || continue
    sshh=$(awk -v ip="$ip" '$0 ~ "ip: *"ip {found=1; next} found && /ssh:/ {gsub(/.*ssh:[[:space:]]*/, ""); gsub(/[[:space:]]+.*/, ""); print; exit}' "$ROOT/config/mesh-nodes.yaml")
    [ -n "$sshh" ] && [ "$sshh" != "null" ] || continue
    # DWIE wartości, bo znaczą co innego:
    #   .Config.Image  → REFERENCJA (tag) — czy nod wdrożył to, co deklaruje compose
    #   RootFS.Layers  → TREŚĆ obrazu — czy pod tym samym tagiem leży ten sam kod
    #
    # KOREKTA 2026-08-26: gate porównywał wyłącznie tag. Tag jest na każdym
    # nodzie identyczny z definicji, więc poziom 2 przechodził ZAWSZE i był
    # ślepy dokładnie na tę awarię, którą miał łapać.
    #
    # NIE porównujemy image ID (.Image), mimo że nagłówek tak obiecywał.
    # `docker save | docker load` — czyli dokładnie ścieżka dystrybucji
    # z ci-deploy.sh — przelicza digest configu, więc TEN SAM obraz dostaje
    # inne ID na nodzie, który przyjął go tarballem. Zmierzone 2026-08-26:
    # prod/contabo/monitor/optiq/kamil miały a9f5ffa2e910, site/mail
    # daaa7820d239 — a sha256 binarki /usr/local/bin/aigon-runtime we
    # WSZYSTKICH siedmiu kontenerach identyczne (85fd9069e9f662e4), tak samo
    # digest warstw (092c31efeb9eca51, 9 warstw). Gate na ID krzyczałby więc
    # bez przerwy, a taki jest równie bezużyteczny jak ten, który milczy.
    # RootFS.Layers to diff ID treści — przechodzi save/load bez zmiany.
    #
    # `ssh -n` OBOWIĄZKOWE: bez tego ssh czyta stdin, czyli strumień pętli
    # `done < <(grep ... mesh-nodes.yaml)`, i połyka wszystkie pozostałe nody.
    # Sweep kończył się po PIERWSZYM nodzie i meldował „PASS: 1 nodów" —
    # przy 8 zadeklarowanych.
    NODE_OUT=$(timeout 15 ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$sshh" '
      ref=$(docker inspect --format "{{.Config.Image}}" aigon-core-runtime 2>/dev/null) || exit 0
      iid=$(docker inspect --format "{{.Image}}" aigon-core-runtime 2>/dev/null) || exit 0
      lay=$(docker image inspect --format "{{range .RootFS.Layers}}{{.}}{{end}}" "$iid" 2>/dev/null | sha256sum | cut -c1-16)
      echo "$ref $lay"' 2>/dev/null)
    RID=$(echo "$NODE_OUT" | awk 'NF{print $1; exit}')
    RIMG=$(echo "$NODE_OUT" | awk 'NF{print $2; exit}')
    [ -n "$RID" ] || continue
    CHECKED=$((CHECKED+1))
    if [ "$RID" != "$EXPECTED" ]; then BAD="$BAD $ip=$RID"; fi
    IDS="$IDS$RIMG $ip"$'\n'
  done < <(grep -E '^\s*ip:' "$ROOT/config/mesh-nodes.yaml")
  # Rozjazd ID przy zgodnych tagach — osobny warunek, nie podzbiór $BAD.
  DISTINCT=$(echo "$IDS" | awk 'NF{print $1}' | sort -u | wc -l)
  # Nagłówek obiecuje „fail-closed: mesh <8/8 = FAIL", ale kodu tego nie było:
  # nod nieosiągalny dawał puste RID, przechodził jako „sprawdzony bez rozjazdu"
  # i gate meldował PASS na próbce, której nie zbadał. Odniesienie to liczba
  # nodów z realnym aliasem ssh (lokalny ma `ssh: null` i sprawdza go poziom 1).
  SSHABLE=$(grep -E '^\s*ssh:' "$ROOT/config/mesh-nodes.yaml" | grep -vc 'null')
  if [ "$CHECKED" -eq 0 ]; then : # brak dostępnych nodów → spadnij do poziomu 3
  elif [ "$CHECKED" -lt "$SSHABLE" ]; then
    echo "FAIL image-consistency (ssh): odpowiedziało $CHECKED z $SSHABLE nodów — brak pokrycia, nie orzekam o spójności"
    exit 1
  elif [ -n "$BAD" ]; then
    echo "FAIL image-consistency (ssh): rozjazd referencji:$BAD"
    exit 1
  elif [ "$DISTINCT" -gt 1 ]; then
    echo "FAIL image-consistency (ssh): $CHECKED nodów ma tag $EXPECTED, ale $DISTINCT różnych ID:"
    echo "$IDS" | awk 'NF{print "  " $1 "  " $2}' | sort
    exit 1
  else
    echo "PASS image-consistency (ssh): $CHECKED nodów == $EXPECTED (ID $(echo "$IDS" | awk 'NF{print $1; exit}'))"
    exit 0
  fi
fi

# ── Poziom 3: fallback /health (user aigon — bez docker/ssh) ──────────
H=$(curl -sk -m 8 "$RUNTIME_URL/health" 2>/dev/null)
if [ -z "$H" ]; then
  echo "FAIL image-consistency: /health niedostępny"
  exit 1
fi
STAT=$(echo "$H" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    m=d.get('mesh',{})
    nodes=m.get('nodes',[])
    healthy=[n for n in nodes if isinstance(n,dict) and n.get('state')=='Healthy']
    print(f\"{len(nodes)} {len(healthy)}\")
except Exception:
    print('? ?')" 2>/dev/null)
PEERS="${STAT% *}"; HEALTHY="${STAT#* }"
if [ "$PEERS" = "?" ]; then
  echo "FAIL image-consistency: /health nie raportuje mesh"
  exit 1
fi
if [ "$PEERS" -ge 8 ] && [ "$HEALTHY" -ge 8 ]; then
  echo "PASS image-consistency (fallback /health): mesh $HEALTHY/8 Healthy (weryfikacja obrazów: runtime:deploy/image-id-vs-registry)"
  exit 0
fi
echo "FAIL image-consistency (fallback /health): mesh $HEALTHY/$PEERS Healthy (<8/8)"
exit 1
