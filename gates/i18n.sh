#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# i18n/i18n.sh — Universal Project Template — Repository Certification Engine
# Moduł: I18N — INTERNACJONALIZACJA
# Dowód koncepcji (PoC): checki INT-01..04 z wymiaru INT (taxonomy.yaml).
#
# Checki:
#   INT-01  i18n-readiness gate'owany ZAWSZE — nawet przy 1 locale.
#           Wymaga zdefiniowanej polityki i18n (i18n/policy.yaml).
#           Fail-closed przy braku. (BLOCKING)
#   INT-02  Locale registry — lista obsługiwanych locale jest zdefiniowana
#           i wersjonowana (i18n/locales.yaml z sekcją `locales:`).
#           Fail-closed przy braku. (BLOCKING)
#   INT-03  Externalized strings — zero hardcoded user-facing strings
#           w kodzie (heurystyczny skan plików źródłowych za stringami
#           w cudzysłowach wyglądającymi jak UI copy). (WARNING)
#   INT-04  RTL readiness — jeśli locales zawierają język RTL
#           (ar, he, fa, ur), layout musi wspierać RTL (flaga `rtl: true`
#           w locales.yaml). (WARNING)
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== I18N — INTERNACJONALIZACJA ==="

# ── Ścieżki konfiguracji i18n (względem root repo) ──────────
I18N_DIR="$ROOT/i18n"
POLICY_FILE="$I18N_DIR/policy.yaml"
LOCALES_FILE="$I18N_DIR/locales.yaml"

# ── INT-01: i18n-readiness (fail-closed) ────────────────────
# Polityka i18n MUSI istnieć — nawet przy 1 locale. Bez niej serwis nie ma
# zdefiniowanego podejścia do internacjonalizacji → BLOCKING.
if repo_file "$POLICY_FILE"; then
  pass "INT-01 i18n-readiness" BLOCKING "Polityka i18n zdefiniowana: $POLICY_FILE"
else
  fail "INT-01 i18n-readiness" BLOCKING "Brak polityki i18n: $POLICY_FILE (fail-closed — wymagany plik i18n/policy.yaml)"
fi

# ── INT-02: Locale registry (fail-closed) ───────────────────
# Lista obsługiwanych locale musi być zdefiniowana i wersjonowana.
# Wymagana sekcja `locales:` w i18n/locales.yaml.
if repo_file "$LOCALES_FILE" && grep -qE '^[[:space:]]*locales:' "$LOCALES_FILE"; then
  pass "INT-02 Locale registry" BLOCKING "Registry locale zdefiniowany: $LOCALES_FILE (sekcja locales:)"
else
  fail "INT-02 Locale registry" BLOCKING "Brak registry locale: $LOCALES_FILE z sekcją 'locales:' (fail-closed)"
fi

# ── INT-03: Externalized strings (WARNING — heurystyka) ─────
# Heurystyczny skan plików źródłowych za hardcoded stringami, które wyglądają
# jak UI copy (tekst w cudzysłowach, zawierający spacje i litery, nie będący
# kluczem/identyfikatorem). To heurystyka → WARNING, nie BLOCKING.
# Ograniczamy do typowych plików źródłowych, pomijamy pliki konfiguracyjne,
# testy i sam moduł verify (żeby nie generować fałszywych trafień).
INT03_HITS=0
INT03_SAMPLE=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    tools/verify/*|i18n/*|*.md|*.yaml|*.yml|*.json|*.lock|*.min.js|*.min.css) continue ;;
  esac
  # ── NAPRAWA 2026-10-01: ŚMIETNIKI I ARCHIWA TO NIE KOD PRODUKCYJNY ───────
  # `repo_files` ma fallback na listing z dysku (git ls-files bywa pusty), więc
  # wciągał `.dustbin-skills-dedup-*` — katalog usuniętych/duplikowanych skilli.
  # Skutek: 109 153 „trafienia" i próbka z kosza (detektor mierzył nie tę rzecz).
  # Wykluczamy śmietniki/archiwa: to nie jest kod, który ma iść do i18n.
  case "$f" in
    .dustbin*|*/.dustbin*|*/_archive/*|.archive/*|*/.archive/*|*/node_modules/*|*/target/*) continue ;;
  esac
  case "$f" in
    *.py|*.js|*.jsx|*.ts|*.tsx|*.go|*.rs|*.rb|*.php|*.java|*.kt|*.swift|*.c|*.cpp|*.h)
      # Szukamy stringów w cudzysłowach zawierających spację i litery
      # (typowy UI copy), pomijając czyste identyfikatory/klucze.
      #
      # ── NAPRAWA 2026-10-01: BRAMKA WISIAŁA (zmierzone, rc=124 po 90 s) ────
      # BYŁO: dla każdego pliku pętla `while read line` + `printf | grep -qE`
      # NA KAŻDĄ LINIĘ → dziesiątki tysięcy podpowłok na tym repo. Moduł nie
      # kończył się nigdy, więc CAŁY `verify reconcile` stał na i18n (11 modułów
      # PASS / 9 FAIL i brak EXIT po godzinie). Wisząca bramka jest gorsza niż
      # czerwona: nie wiadomo, czy przebieg się skończył.
      # JEST: JEDEN przebieg grep na plik; liczymy linie `wc -l` (nie `grep -q`
      # w potoku — pod `pipefail` łapie SIGPIPE i daje fałszywe rc, zmierzone
      # wcześniej w tym repo), próbkę bierzemy z pierwszej linii.
      matches=$(grep -nE '"[^"]*[A-Za-z][^"]* [^"]*"' "$f" 2>/dev/null) || true
      [ -n "$matches" ] || continue
      n=$(printf '%s\n' "$matches" | wc -l)
      INT03_HITS=$((INT03_HITS+n))
      if [ -z "$INT03_SAMPLE" ]; then
        INT03_SAMPLE="$f: $(printf '%s\n' "$matches" | head -1 | cut -c1-80)"
      fi
      ;;
  esac
done < <(repo_files)

if [ "$INT03_HITS" -eq 0 ]; then
  pass "INT-03 Externalized strings" WARNING "Brak wykrytych hardcoded UI stringów w plikach źródłowych (heurystyka)."
else
  warn "INT-03 Externalized strings" "Wykryto $INT03_HITS potencjalnie hardcoded UI stringów (heurystyka). Przykład: $INT03_SAMPLE"
fi

# ── INT-04: RTL readiness (WARNING) ─────────────────────────
# Jeśli locales zawierają język RTL (ar, he, fa, ur), layout musi wspierać
# RTL (flaga `rtl: true` w locales.yaml). WARNING — nie blokuje.
RTL_LANGS="ar he fa ur"
RTL_FOUND=""
if repo_file "$LOCALES_FILE"; then
  # Wyciągnij listę locale z sekcji locales: (wartości po dwukropku).
  while IFS= read -r loc; do
    # Usuń wiodące spacje, wiodący '-' (element listy YAML), komentarze
    # i cudzysłowy; znormalizuj do małych liter.
    loc="$(printf '%s' "$loc" | sed 's/^[[:space:]]*//; s/^-//; s/^[[:space:]]*//; s/[:#].*$//; s/["'"'"']//g' | tr '[:upper:]' '[:lower:]')"
    [ -z "$loc" ] && continue
    for lang in $RTL_LANGS; do
      case "$loc" in
        "$lang"|"$lang-"*|"$lang"_*) RTL_FOUND="$RTL_FOUND $loc" ;;
      esac
    done
  done < <(sed -n '/^[[:space:]]*locales:/,/^[[:space:]]*[a-zA-Z]/p' "$LOCALES_FILE" 2>/dev/null | grep -E '^[[:space:]]*-' || true)
fi

if [ -n "$RTL_FOUND" ]; then
  if grep -qE '^[[:space:]]*rtl:[[:space:]]*true' "$LOCALES_FILE"; then
    pass "INT-04 RTL readiness" WARNING "Wykryto locale RTL ($RTL_FOUND) i flaga rtl: true jest ustawiona."
  else
    warn "INT-04 RTL readiness" "Wykryto locale RTL ($RTL_FOUND) ale brak flagi 'rtl: true' w $LOCALES_FILE — layout może nie wspierać RTL."
  fi
else
  pass "INT-04 RTL readiness" WARNING "Brak locale RTL (ar/he/fa/ur) — RTL readiness nie dotyczy."
fi

# ── Evidence: moduł zakończony ──────────────────────────────
if verify_blocked; then
  evidence_record "verify:i18n:FAIL" "verify" "i18n/i18n.sh"
else
  evidence_record "verify:i18n:PASS" "verify" "i18n/i18n.sh"
fi

verify_module_exit
