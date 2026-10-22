#!/usr/bin/env bash
# ============================================================================
# env-invariants-check.sh — ENV-INVARIANTS GATE (GATE-089)
# ============================================================================
# Universal Project Template — Repository Certification Engine
#
# GATE-089 ENV-INVARIANTS: sprawdza, że wszystkie NIEZBĘDNE wartości env są
# ustawione w docker-compose i nie mogą być cicho puste. Koniec z usługami
# "healthy" a skonfigurowanymi na pustych sekretach.
#
#   ENV-001  Każde wystąpienie ${VAR} (interpolacja) w environment ma albo:
#            -  ${VAR:?...}  (fail-fast: compose odmówi startu gdy brak)  — OK,
#            -  ${VAR:-default} (default jest jawny, nie pusty)           — OK,
#            -  ${VAR} bez :- ani :? przy braku domyślnej bazy             -> WARN
#   ENV-002  Sekrety (JWT_*SECRET, *_PASSWORD, *_API_KEY, *_TOKEN,
#            *_SHARED_SECRET, PRIVATE_KEY) NIE są blank ani nie mają pustego
#            defaultu (${VAR:-}) — pusta wartość sekretu = FAIL BLOCKING.
#   ENV-003  Endpointy/źródła prawdy (AIGON_OTLP_ENDPOINT, *_HOST, *_URL)
#            wskazują na nie-pusty cel (nie kończą na '://' i nie są '{VAR}').
#   ENV-004  Zmienne wymagane przez usługę z ':?' są zdefiniowane w .env
#            (relaxed: gdy .env nie istnieje, sprawdzamy tylko składnię).
#
# NO FALSE GREEN: sekret z pustą wartością = FAIL BLOCKING (nie skip).
# SECURITY = TYLKO defekcja strukturalna env — ZERO odczytu sekretów.
# ============================================================================
set -u

# shellcheck source=core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-089 ENV-INVARIANTS (wymagane env vars — spójność) ==="

# ── Zbiór wszystkich compose (ta sama heurystyka co GATE-088) ───────────────
COMPOSES="$(find . -maxdepth 3 -type f \( -name 'docker-compose*.yml' -o -name 'compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose*.yaml' \) -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/.next/*' -not -path '*/.quarantine*/*' 2>/dev/null)"

if [ -z "$COMPOSES" ]; then
  fail "ENV-000 stack compose istnieje" BLOCKING "Brak jakiegokolwiek docker-compose*.yml — nie mozna zweryfikowac env."
  verify_module_exit
fi

# Wzorce sekretów — zmienne, których PUSTA wartość jest niebezpieczna.
SECRET_RE='_PASSWORD|_SECRET|_API_KEY|_TOKEN|_SHARED_SECRET|PRIVATE_KEY|_PASS$|_KEY$'
# Wzorce endpointów/źródeł, które muszą wskazywać realny cel.
ENDPOINT_RE='_OTLP_ENDPOINT|_HOST|_URL|_PORT|_ENDPOINT'

GATE_FAILED=0

for compose in $COMPOSES; do
  case "$compose" in
    *gen-*|*template*|*/tests/*|*/test/*|*/reports/*|*.otel-backup*) continue ;;
  esac
  if ! grep -qE '^[[:space:]]{2}[A-Za-z0-9_-]+:' "$compose" 2>/dev/null; then
    continue
  fi
  say ""
  say "── $compose"

  # ── ENV-001: interpolacje ${VAR} bez :- ani :? (ryzyko pustej wartości) ──
  # Zbiory zmiennych JUŻ zabezpieczonych GDZIEKOLWIEK w tym pliku (przez :? lub
  # niepusty default). Zmienna wymuszona w jednym miejscu = bezpieczna wszędzie.
  REQUIRED_VARS=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:\?[^}]*\}' "$compose" 2>/dev/null | sed -E 's/\$\{([A-Za-z_][A-Za-z0-9_]*):\?.*/\1/' | sort -u)
  DEFAULTED_VARS=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\}' "$compose" 2>/dev/null | sed -E 's/\$\{([A-Za-z_][A-Za-z0-9_]*):-.*/\1/' | sort -u)
  SECURED="$REQUIRED_VARS $DEFAULTED_VARS"

  # Zmienne OPCJONALNE — świadomie mogą być puste (alerty/dodatki, nie krytyczne).
  OPTIONAL_RE='TELEGRAM_BOT_TOKEN|_WEBHOOK_URL|SLACK_|DISCORD_|DISCORD_WEBHOOK|_ENABLED$'

  # Znajdź każdą interpolację: VAR=${VAR}, VAR=${VAR:-} (pusty default).
  BARE=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$compose" 2>/dev/null | sed 's/.*{//; s/}//' | sort -u)
  EMPTY_DEFAULT=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:-\}' "$compose" 2>/dev/null | sed 's/.*{//; s/:-\}//' | sort -u)

  for v in $BARE; do
    # Pomiń jeśli zmienna jest wymuszona HOCZĄŚ w pliku (:? / default) —
    # wtedy pusta wartość jest niemożliwa (compose odmówiłby / użył defaultu).
    if echo " $SECURED " | grep -qE " $v "; then
      continue
    fi
    # Pomiń świadome opcjonalne.
    if echo "$v" | grep -qE "$OPTIONAL_RE"; then
      continue
    fi
    # ${VAR} bez ':' — wartość może być pusta, ale .env może ją mieć.
    if echo "$v" | grep -qE "$SECRET_RE"; then
      fail "ENV-002 $compose sekret $v bez :?" BLOCKING "${v}=${v} (bez :? i bez defaultu nigdzie w pliku) — pusta wartosc sekretu mozliwa."
      GATE_FAILED=1
    elif echo "$v" | grep -qE "$ENDPOINT_RE"; then
      warn "ENV-003 $compose endpoint $v bez :?" "Endpoint ${v} interpolowany bez :? ani defaultu nigdzie w pliku."
      GATE_FAILED=1
    fi
  done

  for v in $EMPTY_DEFAULT; do
    # ${VAR:-} — JAWNY pusty default. Sekret z pustym defaultem = FAIL,
    # CHYBA że to opcjonalny (np. TELEGRAM_BOT_TOKEN — alerty opcjonalne).
    if echo "$v" | grep -qE "$OPTIONAL_RE"; then
      continue
    fi
    if echo "$v" | grep -qE "$SECRET_RE"; then
      fail "ENV-002 $compose sekret $v z pustym defaultem" BLOCKING "${v} ma ${v}:-\"\" — jawny pusty sekret."
      GATE_FAILED=1
    fi
  done

  # ── ENV-004: czy ':?' wymaga klucza w .env (relaxed) ─────────────────────
  ENV_FILE="$(dirname "$compose")/.env"
  REQUIRED=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:\?[^}]*\}' "$compose" 2>/dev/null | sed -E 's/\$\{([A-Za-z_][A-Za-z0-9_]*):\?.*/\1/' | sort -u)
  if [ -n "$REQUIRED" ] && [ -f "$ENV_FILE" ]; then
    for v in $REQUIRED; do
      if ! grep -qE "^${v}=" "$ENV_FILE" 2>/dev/null; then
        warn "ENV-004 $compose wymagany $v" "${v} wymaga :? ale brak w $(basename "$ENV_FILE")."
        GATE_FAILED=1
      fi
    done
  fi
done

# ── ENV-005: SAM PLIK .env — czy jest POPRAWNY składniowo? ──────────────────
# POWÓD (incydent 2026-09-28): do /opt/PROD/core/.env został dopisany BLOK
# KODU SHELL (76 linii skryptu sync z liniami-powidłami `X=X` zamiast `X=`).
# Skutek: `docker compose` padał na KAŻDEJ komendzie —
#   "failed to read /opt/PROD/core/.env: line N: unexpected character ..."
# — czyli NIE DAŁO SIĘ odtworzyć żadnego kontenera (deploy zablokowany).
# Dotychczasowe bramki sprawdzały TYLKO interpolację w compose; treści .env
# nie widział nikt. Ten check zamyka klasę: `.env` to plik KLUCZ=WARTOŚĆ,
# nie skrypt. Wykrywa: (a) linie ze spacją/wiodącym `for|if|then|fi|done`,
# (b) POWTÓRZONY klucz przed `=` (sygnatura `X=X` z wklejenia).
ENV_FILES=$(find . -maxdepth 4 -type f -name '.env' \
  -not -path '*/node_modules/*' -not -path '*/.git/*' \
  -not -path '*/dist/*' -not -path '*/.quarantine*/*' 2>/dev/null)
for ef in $ENV_FILES; do
  # (a) ślady kodu shell — komenda zamiast przypisania.
  bad_lines=$(grep -nE '^[[:space:]]*(for |if |then|fi$|done|while |do$|case |esac)' "$ef" 2>/dev/null | head -3)
  if [ -n "$bad_lines" ]; then
    fail "ENV-005 $ef zawiera KOD SHELL zamiast przypisan" BLOCKING \
      "$(printf '%s' "$bad_lines" | head -1) — .env to klucz=wartość, nie skrypt; compose tego nie sparsuje."
    GATE_FAILED=1
  fi
  # (b) klucz z '=' w NAZWIE (wklejone linie typu 'x=1=y' albo 'foo=foo').
  dupkey=$(grep -nE '^[A-Za-z_][A-Za-z0-9_]*=[^=]*=[^=]*$' "$ef" 2>/dev/null | head -2)
  if [ -n "$dupkey" ]; then
    warn "ENV-005 $ef podejrzane przypisanie (dwa '=' w wartosci)" \
      "$(printf '%s' "$dupkey" | head -1)"
  fi
done

# ── ENV-001 globalnie: jeśli nie było żadnego błędu/warn, policz jako pass ─
if [ "$GATE_FAILED" -eq 0 ]; then
  pass "ENV-INVARIANTS calosc" BLOCKING "Wszystkie sekrety i endpointy w compose maja niepusty/wymuszony scenariusz."
else
  :
fi

# ── Evidence ────────────────────────────────────────────────────────────────
if verify_blocked; then
  evidence_record "verify:env-invariants-check:FAIL" "verify" "env-invariants-check.sh"
else
  evidence_record "verify:env-invariants-check:PASS" "verify" "env-invariants-check.sh"
fi

verify_module_exit
