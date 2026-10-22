#!/usr/bin/env bash
# ============================================================================
# gates/domains/hermes-state-db.sh — bramka stanu ~/.hermes/state.db
# ============================================================================
# Po co: baza sesji Hermesa puchla do 11 GB i powodowala
# COMPRESSION_FAILED_API_ERROR. Przyczyny byly DWIE i obie ciche:
#   1. SIEROTY sesji — proces umierajacy nie zapisuje ended_at, a prune
#      wymagalo `ended_at IS NOT NULL` => rekord niesmiertelny.
#   2. TRIGRAM FTS — 5,3 GB indeksu CJK odtwarzane przy KAZDYM starcie.
# Ta bramka lapie NAWRÓT obu zjawisk, zanim baza znowu spuchnie.
#
# BLOCKING: sieroty narastajace szybko albo trigram obecny (regresja).
# WARNING:  baza > prog rozmiaru (wymaga uwagi, nie blokuje).
# ============================================================================
set -uo pipefail

DB="${HERMES_STATE_DB:-$HOME/.hermes/state.db}"
MAX_GB="${HERMES_STATE_DB_MAX_GB:-6}"
MAX_ORPHANS="${HERMES_STATE_DB_MAX_ORPHANS:-50}"
GRACE_H="${HERMES_STATE_DB_GRACE_H:-12}"

fail() { echo "FAIL: $*"; exit 1; }
warn() { echo "WARN: $*"; exit 0; }
ok()   { echo "OK: $*"; exit 0; }

# Baza jest zywa i moze byc zablokowana przez wiele sesji Hermesa. Bramka nie
# moze wisiec w CI — kazdy odczyt dostaje wlasny budzet czasu i wlasny tryb
# tylko-do-odczytu. dbstat skanuje CALA baze, wiec jest najdrozszy.
SQL_TIMEOUT="${HERMES_STATE_DB_SQL_TIMEOUT:-45}"
q() { timeout "$SQL_TIMEOUT" sqlite3 -readonly "$DB" "$1" 2>/dev/null; }

[ -f "$DB" ] || ok "brak $DB — nic do sprawdzenia"

command -v sqlite3 >/dev/null 2>&1 || fail "brak sqlite3"

# ── 0. HAMULEC I/O (incydent 2026-09-24, load 201) ──
# quick_check na bazie 4,6 GB to ciezkie I/O. Odpalony W TRAKCIE backupu NAS
# przez autofs + cargo build => load 201/24 rdzenie, procesy w D-state,
# "database is locked". Ta bramka NIE MOZE dokladac sie do zakorkowania.
# Gdy system zajety: NIE skanujemy — WARN (nie FAIL), bo brak pomiaru
# nie jest dowodem awarii bazy.
GUARD="/opt/PROD/scripts/aigon-heavy-io-guard.sh"
if [ -x "$GUARD" ]; then
  if ! "$GUARD" --check "quick_check $(basename "$DB")" "4.6GB" >/dev/null 2>&1; then
    warn "pomijam quick_check — system pod ciezkim I/O ($("$GUARD" --check "x" "y" 2>&1 | head -1)); bramka NIE skanuje bazy w zakorkowaniu"
  fi
fi

# ── 1. Integralnosc (twardy warunek) ──
# quick_check na bazie ~4,6 GB trwa >45 s (zmierzone: 45 s to za malo, rc=124).
# Dostaje wlasny, dluzszy budzet; przy przekroczeniu NIE raportujemy FAIL —
# brak pomiaru nie jest dowodem uszkodzenia (ta sama zasada co hamulec I/O).
CHK_TIMEOUT="${HERMES_STATE_DB_CHECK_TIMEOUT:-300}"
chk=$(timeout "$CHK_TIMEOUT" sqlite3 -readonly "$DB" "PRAGMA quick_check;" 2>&1 | head -1)
chk_rc=${PIPESTATUS[0]:-$?}
if [ "$chk_rc" -eq 124 ]; then
    warn "quick_check nie zmiescil sie w ${CHK_TIMEOUT}s (baza zajeta/duza) — pomijam; nie jest to dowod uszkodzenia"
fi
[ "$chk" = "ok" ] || fail "quick_check != ok: ${chk:-<pusty wynik, rc=$chk_rc>}"

# ── 2. Trigram FTS — regresja tylko gdy realnie puchnie ──
# UWAGA (zmierzone 2026-09-24): sesje wystartowane PRZED dodaniem flagi nie maja
# jej w swoim env i odtwarzaja PUSTY indeks (CREATE VIRTUAL TABLE IF NOT EXISTS)
# przy kazdym otwarciu bazy. Pusty szkielet to ~4 MB, nie 5,3 GB — te 5,3 GB to
# byl indeks z pelna historia (1,05 mln wiadomosci). Dlatego alarmujemy o
# ROZMIARZE, nie o samym istnieniu: pusty szkielet nie jest krytyczny, ale
# indeks rosniacy przez triggery = realny wyciek. Gdy wszystkie sesje beda mialy
# flage, tabela przestanie powstawac calkowicie.
trigram_mb=$(q "SELECT COALESCE(SUM(pgsize),0)/1024/1024 FROM dbstat WHERE name LIKE 'messages_fts_trigram%';"); trigram_mb=${trigram_mb:-0}
trigram_objs=$(q "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'messages_fts_trigram%';"); trigram_objs=${trigram_objs:-0}
TRIGRAM_MB_BLOCKING="${HERMES_STATE_DB_TRIGRAM_MB:-100}"
if [ "${trigram_mb:-0}" -ge "$TRIGRAM_MB_BLOCKING" ] 2>/dev/null; then
    fail "trigram FTS ${trigram_mb}MB (prog ${TRIGRAM_MB_BLOCKING}MB) — indeks CJK puchnie; ustaw HERMES_DISABLE_FTS_TRIGRAM=1 we WSZYSTKICH miejscach startu (launcher, .bashrc, unit systemd hermes-gateway, skrypt cron) i usun (drop-trigram-fts.py)"
fi
trigram_note=""
if [ "${trigram_objs:-0}" -gt 0 ] 2>/dev/null; then
    trigram_note=" [uwaga: pusty szkielet trigram ${trigram_mb}MB od zywych sesji bez flagi — zniknie gdy je zrestartujesz]"
fi

# ── 3. Glowny FTS nadal istnieje (gdyby ktos usunal za duzo) ──
fts=$(q "SELECT COUNT(*) FROM sqlite_master WHERE name='messages_fts';"); fts=${fts:-0}
[ "$fts" = "1" ] || fail "messages_fts zniknal — wyszukiwanie sesji niedziala"

# ── 4. Sieroty (narastajacy wyciek) ──
now=$(date +%s)
cut=$(( now - GRACE_H * 3600 ))
orphans=$(q "SELECT COUNT(*) FROM sessions WHERE ended_at IS NULL AND started_at < $cut;"); orphans=${orphans:-0}
if [ "$orphans" -gt "$MAX_ORPHANS" ] 2>/dev/null; then
    fail "${orphans} sierot sesji (>${MAX_ORPHANS}) — reap-abandoned-sessions.py nie dziala albo end_reason nie jest zapisywany; cron: hermes-state-maintenance.sh"
fi

# ── 5. Rozmiar (WARNING, nie blocking) ──
bytes=$(stat -c %s "$DB" 2>/dev/null || echo 0)
gb=$(( bytes / 1073741824 ))
if [ "$gb" -ge "$MAX_GB" ] 2>/dev/null; then
    warn "state.db ${gb}GB (prog ${MAX_GB}GB) — sieroty=${orphans}, trigram=${trigram_mb}MB; rozwaz VACUUM + sprawdzenie biezacej sesji"
fi

ok "state.db: $(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1073741824}')GB, trigram=${trigram_mb}MB, sieroty=${orphans}, quick_check=ok${trigram_note}"
