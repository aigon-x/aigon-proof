#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/image-id-vs-registry.sh — gate image-id-vs-registry
#
#  Runtime:deploy (block_on_fail=true) — kontener działa na obrazie
#  zadeklarowanym w docker-compose.yml (:production), nie na starym.
#  Wymaga docker (deploy wykonuje root) — brak docker = FAIL (fail-closed,
#  bo to brama wydania: nie da się zweryfikować → nie można wydać).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"

if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL image-id-vs-registry: docker niedostępny (deploy wymaga roota z dockerem)"
  exit 1
fi

# Obraz serwisu compose, KTÓREGO container_name to aigon-core-runtime —
# nie pierwszy image: w pliku (pierwszy serwis to postgres:16-alpine i
# porównanie z nim zawsze FAILowało, zanieczyszczając evidence RELEASE).
SVC_START=$(grep -n 'container_name: aigon-core-runtime' "$COMPOSE" | head -1 | cut -d: -f1)
SVC_HEAD=$(awk -v s="$SVC_START" 'NR<=s && /^  [a-zA-Z0-9_-]+:/{l=NR} END{print l}' "$COMPOSE")
EXPECTED=$(awk -v h="$SVC_HEAD" 'NR>h && /^  [a-zA-Z0-9_-]+:/{exit} NR>h && /^    image:/{sub(/^[[:space:]]*image:[[:space:]]*/, ""); print; exit}' "$COMPOSE" | tr -d '"'"'"'')
if [ -z "$EXPECTED" ]; then
  echo "FAIL image-id-vs-registry: brak image: dla serwisu aigon-core-runtime w docker-compose.yml"
  exit 1
fi

RUNNING=$(timeout 15 docker inspect --format '{{.Config.Image}}' aigon-core-runtime 2>/dev/null || echo "")
if [ -z "$RUNNING" ]; then
  echo "FAIL image-id-vs-registry: kontener aigon-core-runtime nie działa"
  exit 1
fi

if [ "$RUNNING" != "$EXPECTED" ]; then
  echo "FAIL image-id-vs-registry: kontener=$RUNNING != compose=$EXPECTED"
  exit 1
fi

# A mutable tag is not identity: an existing container keeps its old .Image
# when the tag is moved. Read all three identities without pulling/recreating.
STATE=$(timeout 15 docker inspect --format '{{.State.Running}}' aigon-core-runtime 2>/dev/null || echo "")
ACTUAL_ID=$(timeout 15 docker inspect --format '{{.Image}}' aigon-core-runtime 2>/dev/null || echo "")
TAG_ID=$(timeout 15 docker image inspect --format '{{.Id}}' "$EXPECTED" 2>/dev/null || echo "")
if [ "$STATE" != true ]; then
  echo "FAIL image-id-vs-registry: kontener nie jest running"
  exit 1
fi
if [[ ! "$ACTUAL_ID" =~ ^sha256:[a-f0-9]{64}$ ]] || [[ ! "$TAG_ID" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "UNKNOWN image-id-vs-registry: brak poprawnego digestu kontenera lub lokalnego tagu; wydanie zablokowane"
  exit 1
fi
if [ "$ACTUAL_ID" != "$TAG_ID" ]; then
  echo "FAIL image-id-vs-registry: actual=$ACTUAL_ID != tag=$TAG_ID (nazwa tagu nie dowodzi aktualnego obrazu)"
  exit 1
fi

# Docker CLI uses its existing registry credentials; never print auth or raw
# registry errors. Missing registry/platform evidence must not become PASS.
if ! MANIFEST=$(timeout 20 docker manifest inspect --verbose "$EXPECTED" 2>/dev/null); then
  echo "UNKNOWN image-id-vs-registry: registry manifest niedostępny; wydanie zablokowane"
  exit 1
fi
REGISTRY_IDS=$(printf '%s' "$MANIFEST" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,dict); print(d.get("SchemaV2Manifest",{}).get("config",{}).get("digest",""), d.get("Descriptor",{}).get("digest",""))' 2>/dev/null) || REGISTRY_IDS=""
read -r REGISTRY_CONFIG_ID REGISTRY_MANIFEST_ID <<< "$REGISTRY_IDS"
if [[ ! "$REGISTRY_CONFIG_ID" =~ ^sha256:[a-f0-9]{64}$ ]] || [[ ! "$REGISTRY_MANIFEST_ID" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "UNKNOWN image-id-vs-registry: brak jednoznacznych config/manifest digest (np. indeks platform); wydanie zablokowane"
  exit 1
fi
# Canonical Docker storage variants: overlay2 identifies images by config
# digest; containerd may identify the same image by OCI manifest digest.
# Both must originate from this one registry response, never from a tag alone.
if [ "$ACTUAL_ID" != "$REGISTRY_CONFIG_ID" ] && [ "$ACTUAL_ID" != "$REGISTRY_MANIFEST_ID" ]; then
  echo "FAIL image-id-vs-registry: actual=$ACTUAL_ID != registry config=$REGISTRY_CONFIG_ID / manifest=$REGISTRY_MANIFEST_ID"
  exit 1
fi
echo "PASS image-id-vs-registry: running=true, compose=$EXPECTED, actual=tag=$ACTUAL_ID, registry config=$REGISTRY_CONFIG_ID / manifest=$REGISTRY_MANIFEST_ID"
