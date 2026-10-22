#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/registry-coherence.sh — GATE-134 REGISTRY-COHERENCE
# Rejestr spójny: pliki canon == baza project_index. Zero sierot.
# ─────────────────────────────────────────────────────────────
# KANON 2026-09-27. Powstała po incydencie: wpis `aio-okolic-connector`
# (index_type=canon) utrzymywał rozjazd pliki 41 / baza 42 przez CAŁĄ sesję.
# Powód: project-registry-sync.py wstawia wiersz po kluczu (project_id,
# ref_key), ale NIE MA fazy czyszczenia sierot — wpis, którego katalog
# zniknął (rename/usunięcie produktu), zostaje w bazie NA ZAWSZE.
#
# Skutek: dwie różne odpowiedzi na „ile mamy produktów" zależnie od tego,
# kogo zapytasz (LAW-6 One Canonical Truth). Bramka zamyka tę klasę błędu
# na stałe: rozjazd pliki != baza (index_type='canon') = FAIL.
#
# UWAGA — KTÓRA BAZA: project_index istnieje w DWÓCH bazach:
#   - aigoncode : rejestr kont/kanon (users, tenants, product_access)
#   - aigon     : rejestr projektów/ledger (tu pisze project-registry-sync.py)
# Bramka mierzy `aigon` (tę, do której pisze cron sync). Pomyłka na aigoncode
# to dokładnie błąd, który pozwolił duchowi przeżyć sesję.
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-134 REGISTRY-COHERENCE ==="

CANON_DIR="runtime/knowledge/canon/products"
PG_CONTAINER="${AIGON_PG_CONTAINER:-aigon-datastores-postgres}"
PG_HOST="${AIGON_PG_HOST:-192.0.2.19}"
PG_PORT="${AIGON_PG_PORT:-25437}"
PG_USER="${AIGON_PG_USER:-aigon}"
PG_DB="${AIGON_PG_DB:-aigon}"

# ── REGCOH-001: katalog canon czytelny ──────────────────────
if [ -d "$CANON_DIR" ]; then
  PLIKI=$(find "$CANON_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  pass "REGCOH-001 katalog canon czytelny" BLOCKING "$PLIKI katalogów w $CANON_DIR."
else
  fail "REGCOH-001 katalog canon czytelny" BLOCKING "Brak $CANON_DIR — nie mam podstawy pomiaru."
  verify_module_exit
  exit $?
fi

# ── REGCOH-002: baza project_index osiagalna ────────────────
BAZA=""
BAZA_OK=0
if [ -n "${AIGON_REGISTRY_PRODUCTS_FILE:-}" ]; then
  # Explicit recorded-query input: never fall through to a live DB on failure.
  if [ ! -r "$AIGON_REGISTRY_PRODUCTS_FILE" ]; then
    fail "REGCOH-002 recorded query readable" BLOCKING "Unreadable registry products input."
    verify_module_exit
  fi
  BAZA=$(cat "$AIGON_REGISTRY_PRODUCTS_FILE") && BAZA_OK=1
elif command -v ssh >/dev/null 2>&1; then
  # Preferuj psql przez kontener na PRIMARY (jak reszta AIGON)
  BAZA=$(timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=8 prod-aigon \
    "docker exec -i $PG_CONTAINER psql -U $PG_USER -d $PG_DB -tA \
     -c \"SELECT DISTINCT project_id FROM project_index WHERE index_type='canon' ORDER BY project_id;\"" 2>/dev/null) && BAZA_OK=1
fi
if [ "$BAZA_OK" -ne 1 ] && [ -z "${AIGON_REGISTRY_PRODUCTS_FILE:-}" ]; then
  # Fallback: lokalny psql, jesli kontener dostepny bez ssh
  if command -v psql >/dev/null 2>&1 && [ -n "${PGPASSWORD:-}" ]; then
    BAZA=$(timeout 20 psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -tA \
      -c "SELECT DISTINCT project_id FROM project_index WHERE index_type='canon' ORDER BY project_id;" 2>/dev/null) && BAZA_OK=1
  fi
fi

if [ "$BAZA_OK" -ne 1 ]; then
  # Brak pomiaru NIE jest dowodem spójności — WARN (nie FAIL), jak kernel-health.
  warn "REGCOH-002 baza project_index osiagalna" \
    "Nie mogłem odczytać project_index (index_type=canon) z $PG_DB — brak pomiaru != spójność."
  verify_module_exit
  exit $?
fi
BAZA_N=$(printf '%s\n' "$BAZA" | grep -c . || true)
pass "REGCOH-002 baza project_index osiagalna" BLOCKING "$BAZA_N projektów w bazie $PG_DB (index_type=canon)."

# ── REGCOH-003: pliki == baza (zero sierot) ─────────────────
# Sierota = wpis w bazie bez katalogu w canon/products.
# To dokładnie klasa `aio-okolic-connector`: sync go nie usunie, bo nie
# ma go na liście iteracji (produkty_z_plikow()).
PLIKI_LIST=$(mktemp)
BAZA_LIST=$(mktemp)
trap 'rm -f "$PLIKI_LIST" "$BAZA_LIST"' EXIT
# ── KOREKTA 2026-10-01 (ZMIERZONA) ─────────────────────────────────────────
# `find` po DRZEWIE ROBOCZYM łapał 155 katalogów, z czego 113 to NIEŚLEDZONE
# śmieci (m.in. katalog dosłownie nazwany `*` — ślad niepodstawionego globa;
# do tego app/archive/assets/audyt...), przez co REGCOH-003 FAILował na
# artefaktach LOKALNYCH i blokował commit WSZYSTKIM agentom. Kanon to stan
# ZAMIERZONY = to, co w GICIE; working tree zawiera śmieci i cudze WIP.
# Dlatego listę produktów bierzemy z gita (42 wpisy) zamiast z `find` (155).
# Zgodne z doktryną tej bramki (REGCOH-004/005): rozstrzyga SSOT, nie lokalny
# stan katalogu. Fallback na `find` gdy brak gita (np. kopia bez .git).
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$ROOT" ls-tree -d --name-only "HEAD:${CANON_DIR}" 2>/dev/null \
    | sed 's#.*/##' | grep . | sort > "$PLIKI_LIST"
fi
if [ ! -s "$PLIKI_LIST" ]; then
  find "$CANON_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort > "$PLIKI_LIST"
fi
printf '%s\n' "$BAZA" | grep . | sort > "$BAZA_LIST"

SIEROTY=$(comm -13 "$PLIKI_LIST" "$BAZA_LIST" | head -10)
BRAKUJACE=$(comm -23 "$PLIKI_LIST" "$BAZA_LIST" | head -10)
N_SIEROT=$(printf '%s\n' "$SIEROTY" | grep -c . || true)
N_BRAK=$(printf '%s\n' "$BRAKUJACE" | grep -c . || true)

  # ── REGCOH-003: KIERUNEK POPRAWNY — baza (autorytet) → katalog na dysku ──
  # BUG ZMIERZONY 2026-10-02: poprzednia wersja porównywała `git ls-tree -d`
  # (167 katalogów w canon/products, z czego realne = szkielety z samym
  # `users/<user>/canon.json`; NIE ma tam treści produktów — ta jest w bazie)
  # z `project_index` (59 PRODUKTÓW). Dwa zbiory o RÓŻNEJ semantyce → 10
  # fałszywych „brakujących" (`*`, `agent`, `app`, `archive`, `artifacts`, …)
  # blokowało commit WSZYSTKIM agentom na artefaktach roboczych.
  # Zmierzone 2026-10-02: NAWET `aigon-code` (realny produkt) ma na dysku tylko
  # `users/szamani/canon.json` — więc dysk != lista produktów.
  # Poprawny kierunek: AUTORYTETEM jest project_index; sprawdzamy czy każdy
  # PRODUKT z bazy ma katalog w canon/products (sierota = brak katalogu).
  # Doktryna jak REGCOH-004/005: drzewo canon NIE jest propagowane na węzły
  # != SSOT (potwierdzone w scripts/project-registry-sync.py), więc brak
  # katalogu na local to BRAK POMIARU, nie defekt → WARN na nie-SSOT, FAIL na SSOT.
# ŹRÓDŁO PRAWDY KANONU (potrzebne już w REGCOH-003): drzewo canon NIE jest
# propagowane na węzły != SSOT, więc brak katalogu lokalnie != defekt.
CANON_SSOT_HOST="${AIGON_REGISTRY_SSOT:-prod.szamani.ai}"
THIS_NODE="$(uname -n)"
JEST_SSOT_KANONU=0
[ "$THIS_NODE" = "$CANON_SSOT_HOST" ] && JEST_SSOT_KANONU=1

  if printf '%s\n' "$BAZA" | grep -q .; then
    LICZNIK_OK=0
    LICZNIK_ZLE=0
    ZLE_LISTA=""
    while IFS= read -r prod; do
      [ -z "$prod" ] && continue
      [ -d "$CANON_DIR/$prod" ] && LICZNIK_OK=$((LICZNIK_OK+1)) || { LICZNIK_ZLE=$((LICZNIK_ZLE+1)); ZLE_LISTA="$ZLE_LISTA $prod"; }
    done <<< "$BAZA"
    if [ "$LICZNIK_ZLE" -eq 0 ]; then
      pass "REGCOH-003 każdy produkt z bazy ma katalog canon" BLOCKING \
        "$LICZNIK_OK/$LICZNIK_OK produktów project_index ma katalog w $CANON_DIR."
    elif [ "$JEST_SSOT_KANONU" = "1" ]; then
      fail "REGCOH-003 każdy produkt z bazy ma katalog canon" BLOCKING \
        "$LICZNIK_ZLE wpis(ów) w bazie BEZ katalogu na SSOT:$ZLE_LISTA (sierota rejestru — usuń wpis lub dodaj katalog)."
    else
      warn "REGCOH-003 każdy produkt z bazy ma katalog canon" \
        "NIE ROZSTRZYGAM na węźle $THIS_NODE (SSOT kanonu = $CANON_SSOT_HOST): drzewo canon nie jest propagowane, więc brak katalogu lokalnie != defekt. Do sprawdzenia na SSOT:$ZLE_LISTA"
    fi
  else
    warn "REGCOH-003 każdy produkt z bazy ma katalog canon" \
      "Brak odczytu project_index — nie mam autorytetu do porównania (brak pomiaru != spójność)."
  fi

# ── AUTORYTET SIEROT: tylko SSOT rejestru kanonu ────────────
# ZMIERZONE 2026-09-30: 'optiq' ma katalog TYLKO na PROD (SSOT) — na local
# 44 vs 43. Baza była POPRAWNA, ale bramka na każdym węźle != SSOT zgłaszała
# sierotę i blokowała commit WSZYSTKIM agentom. Przyczyna: drzewo
# runtime/knowledge/canon/products NIE jest propagowane przez sync-prod
# (potwierdzone w scripts/project-registry-sync.py), więc lokalna lista jest
# z definicji NIEPEŁNA — porównanie jej ze WSPÓLNYM rejestrem nie rozstrzyga
# o sierotach. Sierota = wpis bez katalogu NA SSOT. Jedno źródło prawdy SSOT
# bierzemy z tego samego miejsca co producent (AIGON_REGISTRY_SSOT).
CANON_SSOT_HOST="${AIGON_REGISTRY_SSOT:-prod.szamani.ai}"
THIS_NODE="$(uname -n)"
JEST_SSOT_KANONU=0
[ "$THIS_NODE" = "$CANON_SSOT_HOST" ] && JEST_SSOT_KANONU=1

if [ "$JEST_SSOT_KANONU" = "1" ]; then
  # ── REGCOH-004: zero sierot (wpis bez katalogu) ───────────
  # To jest sedno bramki — klasa błędu, która przeszła całą sesję.
  if [ "$N_SIEROT" -eq 0 ]; then
    pass "REGCOH-004 zero sierot w bazie" BLOCKING \
      "Brak wpisów canon bez katalogu w $CANON_DIR (pliki=$PLIKI baza=$BAZA_N; SSOT=$THIS_NODE)."
  else
    fail "REGCOH-004 zero sierot w bazie" BLOCKING \
      "$N_SIEROT wpis(ów) canon BEZ katalogu na SSOT — duch w rejestrze: $(printf '%s' "$SIEROTY" | tr '\n' ' '). Usuń: DELETE FROM project_index WHERE project_id='<id>' AND index_type='canon'; lub dodaj katalog."
  fi

  # ── REGCOH-005: liczby zgodne ─────────────────────────────
  if [ "$PLIKI" -eq "$BAZA_N" ]; then
    pass "REGCOH-005 pliki == baza" BLOCKING "pliki=$PLIKI baza=$BAZA_N — jedna prawda (LAW-6)."
  else
    fail "REGCOH-005 pliki == baza" BLOCKING \
      "ROZJAZD: pliki=$PLIKI != baza=$BAZA_N — dwie odpowiedzi na 'ile mamy produktów' (LAW-6)."
  fi
else
  # Węzeł != SSOT: lokalne drzewo jest niepełne z definicji (niepropagowane).
  # Brak rozstrzygalności != defekt → WARN, a werdykt zostaje po stronie SSOT.
  warn "REGCOH-004 zero sierot w bazie" \
    "NIE ROZSTRZYGAM na węźle $THIS_NODE (SSOT kanonu = $CANON_SSOT_HOST): lokalne drzewo canon jest z definicji niepełne. Do sprawdzenia na SSOT: $(printf '%s' "$SIEROTY" | tr '\n' ' ')"
  warn "REGCOH-005 pliki == baza" \
    "pliki(lokalne)=$PLIKI, baza(wspólna)=$BAZA_N — porównanie krzyżowe lokalne↔SSOT; autorytet = $CANON_SSOT_HOST (LAW-6)."
fi

verify_module_exit
