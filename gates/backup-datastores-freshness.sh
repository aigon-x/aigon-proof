#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/backup-datastores-freshness.sh — gate BACKUP-DATASTORES-FRESHNESS
#
#  PO CO (audyt bram 2026-09-29, skill mesh-resource-sovereign):
#    `scripts/backup-datastores.sh` (redis + surrealdb → NAS) był wołany
#    z crona BEZ ŻADNEJ bramy. To dane klienckie (rejestry, ledger, pamięć
#    agentów) — cichy brak backupu oznacza utratę bez wykrycia. Audyt wykazał
#    151/330 skryptów cron bez pokrycia; ten jest w TOP ryzyka (dane + DB).
#
#  CO MIERZY (skutek, nie akcję): czy na NAS leży ŚWIEŻY, KOMPLETNY backup
#  obu magazynów. Nie sprawdzamy „czy skrypt się uruchomił" — sprawdzamy
#  „czy artefakt istnieje i jest czytelny". Sama akcja bez skutku = FAIL.
#
#  KONTRAKT: exit 0 = PASS, exit 1 = FAIL.
#  Env: BACKUP_ROOT (def. /mnt/nas/aigon-fs/aigon-x/backups/datastores),
#       AIGON_BACKUP_MAX_AGE_H (def. 48 — powyżej = FAIL świeżości).
#
#  PUŁAPKA (zmierzona klasa): brak zamontowanego NAS nie może dawać PASS.
#  „Nie mogłem zmierzyć" != „jest dobrze" — to FAIL z jawnym powodem.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/nas/aigon-fs/aigon-x/backups/datastores}"
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/gate-params.sh"
MAX_AGE_H="$(gp GATE-191 backup_max_age_h 48)"

fails=0
say() { printf '       %s\n' "$*"; }

# ── 1. NAS zamontowany? (brak pomiaru != PASS) ─────────────────────────
if ! mountpoint -q "$(dirname "$BACKUP_ROOT")" 2>/dev/null && [ ! -d "$BACKUP_ROOT" ]; then
  say "FAIL: katalog backupów nieosiągalny ($BACKUP_ROOT) — NAS niezamontowany?"
  say "      Naprawa: sudo /opt/PROD/scripts/nas-mesh-heal.sh (kanon NAS)"
  echo "backup-datastores-freshness: FAIL (brak dostępu do artefaktów)"
  exit 1
fi

# ── 2. Dla każdego magazynu: najświeższy artefakt + wiek + rozmiar ─────
check_store() {
  local name="$1" pattern="$2" magic="${3:-}"
  local newest age_h size
  newest="$(find "$BACKUP_ROOT" -maxdepth 3 -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)"
  if [ -z "$newest" ]; then
    say "FAIL: $name — brak jakiegokolwiek artefaktu ($pattern) w $BACKUP_ROOT"
    fails=$((fails+1)); return
  fi
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$newest" 2>/dev/null || echo 0) ) / 3600 ))
  size=$(stat -c %s "$newest" 2>/dev/null || echo 0)
  # Pusty plik = backup nieudany mimo istnienia nazwy (klasa: nazwa bez treści)
  if [ "$size" -lt 1024 ]; then
    say "FAIL: $name — artefakt ma ${size} B (podejrzanie pusty): $(basename "$newest")"
    fails=$((fails+1)); return
  fi
  # 2026-09-29: MAGIC BYTES — rozmiar NIE wystarcza. Zmierzone: `docker cp <ctr>:<path> -`
  # na docker 29.7.2 streamował NAZWĘ pliku + padding = ~4,6 KB śmiecia, co przechodziło
  # guard rozmiaru i wyglądało jak udany backup. Weryfikujemy POCZĄTEK rozpakowanej treści.
  if [ -n "$magic" ]; then
    local hdr
    hdr="$(gzip -dc "$newest" 2>/dev/null | head -c ${#magic} | tr -d '\0' || true)"
    if [ "$hdr" != "$magic" ]; then
      say "FAIL: $name — treść nie zaczyna się od '${magic}' (jest: '${hdr:0:16}') — artefakt USZKODZONY"
      fails=$((fails+1)); return
    fi
  fi
  if [ "$age_h" -gt "$MAX_AGE_H" ]; then
    say "FAIL: $name — najświeższy ma ${age_h}h (limit ${MAX_AGE_H}h): $(basename "$newest")"
    fails=$((fails+1)); return
  fi
  say "OK:   $name — ${age_h}h, ${size} B, nagłówek OK, $(basename "$newest")"
}

check_store "redis"     "*.rdb.gz"  "REDIS0012"
check_store "surrealdb" "*.tar.gz"  ""

# ── 3. Werdykt ─────────────────────────────────────────────────────────
if [ "$fails" -eq 0 ]; then
  echo "backup-datastores-freshness: PASS (oba magazyny świeże, ≤${MAX_AGE_H}h)"
  exit 0
fi
echo "backup-datastores-freshness: FAIL (${fails} magazyn(y) bez świeżego backupu)"
exit 1
