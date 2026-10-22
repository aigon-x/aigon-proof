#!/usr/bin/env bash
# ============================================================================
#  file-permissions-check.sh — GATE-127: KANON UPRAWNIEŃ PLIKÓW /opt/PROD
#                                                              [qg G247]
# ============================================================================
#  POWÓD (ROOT CAUSE, zmierzony 2026-09-24):
#
#  W repo ISTNIAŁ „czeker praw" — GATE-112 PERMISSION-JUSTIFICATION. Sprawdzał
#  wyłącznie, czy w `artifacts/quality-gates/coverage-matrix-qg300.md` albo
#  `config/canonical/gate-registry.yaml` występuje NAPIS „G246". Nie otwierał
#  ani jednego pliku, nie sprawdzał ani jednego trybu. Wynik: PASS na zawsze,
#  niezależnie od stanu systemu. Zmierzone 2026-09-24: `CERTIFICATION: PASS`,
#  `Checks: 1, FAIL: 0` — przy 1259 plikach łamiących kanon w /opt/PROD.
#  To fałszywy zielony w czystej postaci: bramka istnieje, nic nie pilnuje.
#
#  CO ZŁAPAŁ PRAWDZIWY DEFEKT (bez tego gate'u): `scripts/lib/selfmail.py`
#  zapisany przez proces roota dostał tryb 0600; cron `grant-mail-watchdog`
#  chodzi jako `sniegul` → `PermissionError(13)` przy imporcie → filtr
#  self-alert był MARTWY, a watchdog odrzucał WSZYSTKO (fail-closed) przez
#  15 minut. Funkcja poprawna, plik nieczytelny dla swojego konsumenta.
#  To samo dotyczyło `config/media.yaml` (0620), `config/secrets/*` (0620),
#  `observability/.env` (0600) — pliki konsumowane przez crony nie-roota.
#
#  TEN GATE MIERZY STAN FAKTYCZNY: przechodzi po plikach infra i sprawdza
#  (a) tryb zgodny z rolą pliku, (b) BIT ODCZYTU dla konsumentów, (c) ownera.
#  Fail-closed: brak skryptu audytu = BLOCKING FAIL (nie „skip").
#
#  Unified gate: JEDEN skrypt widoczny jako gate (registry) I jako moduł
#  verify (gates.yaml) — pipeline CI i lokalna certyfikacja egzekwują TO SAMO.
#
#  ZAKRES (świadomie wąski — inaczej szum zabija bramkę):
#    * pliki INFRA: scripts/, config/, observability/, tools/
#    * POMIJANE: node_modules, target, .git, __pycache__, .venv, dist, build
#    * Tryby SZERSZE niż kanon (0664/0775) są RAPORTOWANE jako WARN, nie FAIL —
#      grupa `aigon` ma do nich dostęp i nic nie jest zepsute; twardy FAIL jest
#      tylko tam, gdzie plik ma KONSUMENTA, a ten nie może go odczytać.
# ============================================================================
set -u

. "$(dirname "${BASH_SOURCE[0]}")/core/lib.sh"
ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-127 FILE-PERMISSIONS (kanon uprawnień /opt/PROD) ==="

AUDIT="scripts/audit-fileperm.py"
LIB="scripts/lib/fileperm.py"

# ── FAIL-CLOSED: brak narzędzia = brak dowodu (NIGDY skip) ──────────────────
if [ ! -f "$AUDIT" ] || [ ! -f "$LIB" ]; then
  fail "GATE-127 narzędzie audytu" BLOCKING \
    "Brak $AUDIT albo $LIB — NIE MOŻNA zmierzyć uprawnień. Brak narzędzia != brak problemu."
  evidence_record "verify:file-permissions:FAIL" "verify" "file-permissions-check.sh"
  verify_module_exit
fi

# ── Samotest kontraktu (uprawnienia + KONTRAKT INODE) ──────────────────────
if ! python3 "$LIB" >/dev/null 2>&1; then
  say "  samotest $LIB NIE PRZESZEDL — szczegoly:"
  python3 "$LIB" 2>&1 | sed 's/^/    /' | head -20
  fail "GATE-127 samotest kontraktu" BLOCKING \
    "scripts/lib/fileperm.py nie przechodzi samotestu (tryby/inode). Kontrakt zapisu jest zepsuty."
  evidence_record "verify:file-permissions:FAIL" "verify" "file-permissions-check.sh"
  verify_module_exit
fi
say "  samotest fileperm.py: OK (tryby 0644/0755 + inode stały przy write_inplace)"

# ── Audyt właściwy — pliki infra ───────────────────────────────────────────
OUT="$(python3 "$AUDIT" --check --limit 25 2>&1)"
RC=$?
say "$OUT" | sed 's/^/  /'

# Twardy FAIL: pliki, których konsument NIE MOŻE odczytać.
# SEMANTYKA (świadoma): 0640 jest POPRAWNE dla plików z sekretami — grupa
# `aigon` czyta (a w niej są crony nie-roota: sniegul), świat nie. Defektem
# jest 0600/0620/0700, czyli brak bitu ODCZYTU DLA GRUPY — wtedy nawet grupa
# właściciela nie przeczyta, a to dokładnie klasa, która zabiła filtr
# self-alert 2026-09-24 (selfmail.py 0600 vs cron sniegul).
# WYKLUCZENIA MUSZĄ BYĆ IDENTYCZNE z scripts/audit-fileperm.py — inaczej obie
# warstwy raportują różne liczby dla tego samego drzewa (zmierzone 2026-09-24:
# audyt Pythona 0 twardych, gate FAIL na node_modules w podkatalogach i na
# pliku, którego audyt nie chodził). Jedna prawda, dwa konsumenty.
UNREADABLE="$(find scripts config observability tools \
  \( -name node_modules -o -name target -o -name .git -o -name __pycache__ \
     -o -name .venv -o -name venv -o -name dist -o -name build -o -name .next \
     -o -name .pytest_cache -o -name .deno -o -name .cargo -o -name .cache \) -prune -o \
  -path 'config/secrets/redis-companion-acl.env' -prune -o \
  -type f ! -perm -040 -print 2>/dev/null | head -40)"

if [ -n "$UNREADABLE" ]; then
  N="$(printf '%s\n' "$UNREADABLE" | wc -l)"
  say "  PLIKI NIEODCZYTYWALNE DLA KONSUMENTA ($N):"
  printf '%s\n' "$UNREADABLE" | sed 's/^/    /'
  fail "GATE-127 pliki nieodczytywalne" BLOCKING \
    "$N plików bez bitu odczytu dla innych (0600/0620/0640) — konsument w innym userze (cron/kontener) dostanie PermissionError. To DOKŁADNIE klasa, która zabiła filtr self-alert 2026-09-24. Naprawa: sudo python3 scripts/audit-fileperm.py --apply"
  evidence_record "verify:file-permissions:FAIL" "verify" "file-permissions-check.sh"
  verify_module_exit
fi

# ── WARN: tryby szersze niż kanon (nie blokują, ale to dług) ───────────────
# Ten sam filtr wykluczeń co przy twardym FAIL wyżej (jedna prawda).
WIDE="$(find scripts config observability tools \
  \( -name node_modules -o -name target -o -name .git -o -name __pycache__ \
     -o -name .venv -o -name venv -o -name dist -o -name build -o -name .next \
     -o -name .pytest_cache -o -name .deno -o -name .cargo -o -name .cache \) -prune -o \
  -type f \( -perm 0664 -o -perm 0775 \) -print 2>/dev/null | wc -l)"
if [ "$WIDE" -gt 0 ]; then
  say "  [WARN] $WIDE plików z trybem szerszym niż kanon (0664/0775) — nie blokuje,"
  say "         grupa aigon ma dostęp; kandydat do normalizacji:"
  say "         sudo python3 scripts/audit-fileperm.py --apply"
fi

if [ "$RC" -ne 0 ]; then
  # ROZRÓŻNIENIE (2026-09-24): tryb SZERSZY (0664/0775) jest długiem, nie
  # defektem — grupa `aigon` ma dostęp, nic nie jest zepsute. Twardy FAIL
  # wyżej łapie wyłącznie brak odczytu dla grupy (klasa selfmail.py 0600).
  # Bez tego rozróżnienia bramka raportowała 1230 „naruszeń" na zdrowym
  # drzewie i nie dało się jej doprowadzić do zielonego — co czyni z bramki
  # dekorację (ta sama klasa co GATE-112 sprawdzający napis „G246").
  WARN_N="$(python3 - <<'PYEOF'
import sys
sys.path.insert(0, "/opt/PROD/scripts/lib")
try:
    from fileperm import audit, audit_counts
    import importlib.util
    spec = importlib.util.spec_from_file_location("aud", "/opt/PROD/scripts/audit-fileperm.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    hard, soft = audit_counts(audit(list(m.walk(["scripts", "config", "observability", "tools"]))))
    print(hard)
except Exception:
    print("?")
PYEOF
)"
  if [ "$WARN_N" = "0" ]; then
    say "  audyt: 0 twardych defektów (tryby szersze niż kanon są długiem, patrz WARN wyżej)"
    pass "GATE-127 FILE-PERMISSIONS calosc" BLOCKING \
      "Kanon uprawnień trzyma: zero plików nieodczytywalnych dla grupy, samotest kontraktu OK."
    evidence_record "verify:file-permissions:PASS" "verify" "file-permissions-check.sh"
    verify_module_exit
  fi
  fail "GATE-127 audyt uprawnień" BLOCKING \
    "Audyt wykrył $WARN_N twardych defektów (plik nieodczytywalny dla grupy). Naprawa: sudo python3 scripts/audit-fileperm.py --apply"
  evidence_record "verify:file-permissions:FAIL" "verify" "file-permissions-check.sh"
  verify_module_exit
fi

pass "GATE-127 FILE-PERMISSIONS calosc" BLOCKING \
  "Kanon uprawnień trzyma: zero plików nieodczytywalnych, samotest kontraktu OK."
evidence_record "verify:file-permissions:PASS" "verify" "file-permissions-check.sh"
verify_module_exit
