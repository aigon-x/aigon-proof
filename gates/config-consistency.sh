#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/config-consistency.sh — gate config-consistency
#
#  Bind-mount drift: atomic write (edit tool / skrypty: tmp+rename) zmienia
#  inode pliku na dysku, a bind mount KONTENERA trzyma stary inode — kontener
#  działa na starym configu, HUP/reload nic nie da (czyta stary inode).
#  Zmierzone 2026-09-06: prometheus.yml na dysku (inode 10269805) vs w
#  kontenerze aigon-observability-prometheus (inode 10267875) — nowe joby
#  scrape nie istniały w działającym Prometheus mimo poprawnego pliku na dysku.
#
#  Metoda: porównanie INODE przez /proc/<pid>/root — bez narzędzi w kontenerze
#  (prom/prometheus to scratch: zero sh/cat/sha256sum; docker cp na bind-mount
#  pliku failuje "device or resource busy" — mount point nie może być
#  nadpisany). docker inspect State.Pid → stat dysku vs stat
#  /proc/<pid>/root/<dst> (podąża za mount namespace kontenera).
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS (wszystkie bind-mount pliki zgodne z dyskiem)
#    exit 1 = FAIL (drift — kontener na starym pliku)
#    exit 2 = błąd środowiska (brak docker / brak dostępu do /proc)
#  Opcje: --json → raport JSON na stdout
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

JSON=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "config-consistency: brak docker"; exit 2; }
docker info >/dev/null 2>&1 || { echo "config-consistency: docker nieosiągalny"; exit 2; }

# /proc/<pid>/root wymaga roota (procesy kontenerów są cudze). Gate w cronie
# (hook-runner / cyclic) działa jako root; lokalnie jako sniegul — fallback
# na porównanie sha256 przez docker cp (dla plików niebusy).
if [ "$(id -u)" != "0" ]; then
  echo "config-consistency: UWAGA — działa jako $(id -un), /proc/<pid>/root niedostępny; używam docker cp (nie złapie plików busy)"
  PROC_ROOT=0
else
  PROC_ROOT=1
fi

DRIFT=0
CHECKED=0
SKIPPED=0
declare -a DRIFTS
declare -a SKIPS

for cid in $(docker ps -q 2>/dev/null); do
  cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  pid=$(docker inspect --format '{{.State.Pid}}' "$cid" 2>/dev/null)
  [ -n "$pid" ] && [ "$pid" != "0" ] || continue

  while IFS='|' read -r src dst; do
    [ -n "$src" ] && [ -n "$dst" ] || continue
    CHECKED=$((CHECKED+1))
    disk_inode=$(stat -c '%i' "$src" 2>/dev/null)
    if [ -z "$disk_inode" ]; then
      SKIPPED=$((SKIPPED+1)); SKIPS+=("$cname:$src (nieczytelny na dysku)")
      continue
    fi
    if [ "$PROC_ROOT" = "1" ]; then
      # Inode który WIDZI kontener (mount namespace) — bez exec w środku.
      cont_inode=$(stat -c '%i' "/proc/$pid/root$dst" 2>/dev/null)
      if [ -z "$cont_inode" ]; then
        SKIPPED=$((SKIPPED+1)); SKIPS+=("$cname:$dst (/proc/$pid/root niedostępny)")
        continue
      fi
      if [ "$disk_inode" != "$cont_inode" ]; then
        DRIFT=$((DRIFT+1))
        DRIFTS+=("$cname $dst (dysk inode=$disk_inode kontener inode=$cont_inode)")
      fi
    else
      # Fallback: sha256 przez docker cp (nie zadziała na busy bind-mount).
      # ── NAPRAWA 2026-10-01: DOWIĄZANIE SYMBOLICZNE = FAŁSZYWY ROZJAZD ──────
      # Zmierzone: host `/etc/localtime` to SYMLINK (-> .../Europe/Warsaw).
      # `sha256sum "$src"` idzie ZA linkiem (treść Warsaw), a `docker cp` kopiuje
      # SAM LINK i rozwiązuje go w przestrzeni hosta inspekcjonującego (wyszło
      # /Etc/UTC) → DWA RÓŻNE HASHE przy ZEROWYM dryfie. Dowód, że kontener ma
      # dobrą strefę: `docker exec <c> sha256sum /etc/localtime` == hash hosta.
      # Detektor mierzył nie tę rzecz (ta sama klasa co node_exporter/health).
      # Restart kontenera NIC by nie naprawił — to bramka była zepsuta.
      if [ -L "$src" ]; then
        SKIPPED=$((SKIPPED+1))
        SKIPS+=("$cname:$dst (host: dowiązanie symboliczne — docker cp nie odwzorowuje go wiernie; pominieto)")
        continue
      fi
      TMPF=$(mktemp)
      if docker cp "$cid:$dst" "$TMPF" >/dev/null 2>&1; then
        disk_hash=$(sha256sum "$src" 2>/dev/null | cut -d' ' -f1)
        cont_hash=$(sha256sum "$TMPF" 2>/dev/null | cut -d' ' -f1)
        rm -f "$TMPF"
        if [ -n "$disk_hash" ] && [ "$disk_hash" != "$cont_hash" ]; then
          DRIFT=$((DRIFT+1))
          DRIFTS+=("$cname $dst (sha256 rozjazd)")
        fi
      else
        SKIPPED=$((SKIPPED+1)); SKIPS+=("$cname:$dst (docker cp busy — pominieto)")
      fi
    fi
  done < <(docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}{{end}}' "$cid" 2>/dev/null | while IFS='|' read -r s d; do [ -f "$s" ] && echo "$s|$d"; done)
done

ncont=$(docker ps -q | wc -l)
if [ "$JSON" = "1" ]; then
  python3 - "$DRIFT" "$CHECKED" "$SKIPPED" "$ncont" "${DRIFTS[@]}" << 'PYEOF'
import json, sys
drift_n, checked, skipped, ncont = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
drifts = sys.argv[5:] if len(sys.argv) > 5 else []
print(json.dumps({"gate": "config-consistency", "status": "FAIL" if drift_n else "PASS",
                  "containers": ncont, "checked": checked, "skipped": skipped,
                  "drift_count": drift_n, "drifts": drifts}, ensure_ascii=False))
PYEOF
else
  echo "config-consistency: sprawdzono $CHECKED bind-mount plików w $ncont kontenerach (pominięto $SKIPPED)"
fi

if [ "$DRIFT" -gt 0 ]; then
  if [ "$JSON" != "1" ]; then
    for d in "${DRIFTS[@]}"; do echo "  DRIFT: $d"; done
    for s in "${SKIPS[@]}"; do echo "  SKIP: $s"; done
  fi
  echo "FAIL config-consistency: $DRIFT plik(ów) bind-mount rozjechanych z dyskiem — kontener działa na starym configu. Fix: docker restart <kontener> (przemontowanie bind mounta) LUB docker cp + restart procesu; sam HUP/reload NIE pomoże (bind mount trzyma stary inode)."
  exit 1
fi

[ "$JSON" = "1" ] || echo "PASS config-consistency: wszystkie bind-mount pliki zgodne z dyskiem (SSOT)"
exit 0
