#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/wiring.sh — GATE-038 G-INTEG (WIRING GATE)
# Dwukierunkowa macierz połączeń między warstwami systemu.
#
# ZASADA NADRZĘDNA: każdy check musi być DWUKIERUNKOWY.
#   declared→exists (FALSE GATE)  ORAZ  exists→declared (ORPHAN)
#   defined→consumed (martwa)     ORAZ  consumed→defined (dangling)
#
# Wykrywa: FALSE GATE, ORPHAN, martwe zmienne, dangling references,
# unconnected checks, missing evidence, broken wiring.
#
# To jest PIERWSZY blokujący gate w pipeline (LOCAL_FAST) — weryfikuje
# sam szkielet zanim cokolwiek innego.
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-038 G-INTEG (WIRING GATE) ==="

GATES_DIR="./tools/verify/gates"
DOMAINS_DIR="$GATES_DIR/domains"
REGISTRY="$GATES_DIR/registry.sh"
EVIDENCE_DIR="./artifacts/evidence/gates"
STATE_DIR="./system/control-plane/state"
MIGRATIONS_DIR="$STATE_DIR/migrations"
CI_DIR="./.github/workflows"
HOOKS_DIR="./.git-hooks"
CONFIG_DIR="./config"
DOCS_DIR="./docs"

# ── INTEG-001: moduł w profilu → skrypt istnieje (declared→exists) ──
# Każdy gate zarejestrowany w registry (nie PROPOSED) musi mieć skrypt.
if [ -f "$REGISTRY" ]; then
  # shellcheck source=registry.sh
  . "$REGISTRY"
  FALSE_GATE=0
  FALSE_GATE_DETAIL=""
  for gate_id in $(registry_gate_ids); do
    status="$(registry_field "$gate_id" 22)"
    if [ "$status" = "PROPOSED" ]; then
      continue
    fi
    cmd="$(registry_field "$gate_id" 8)"
    if [ -z "$cmd" ] || [ ! -f "$cmd" ]; then
      FALSE_GATE=$((FALSE_GATE+1))
      FALSE_GATE_DETAIL="$FALSE_GATE_DETAIL $gate_id"
    fi
  done
  if [ "$FALSE_GATE" -eq 0 ]; then
    pass "INTEG-001 declared→exists (brak FALSE GATE)" BLOCKING "Każdy gate w registry ma skrypt implementacji."
  else
    fail "INTEG-001 declared→exists (brak FALSE GATE)" BLOCKING "$FALSE_GATE FALSE GATE (zadeklarowany bez implementacji):$FALSE_GATE_DETAIL"
  fi
fi

# ── INTEG-002: skrypt w domains/ → jest w registry (exists→declared) ──
# Każdy skrypt implementacji musi mieć wpis w registry (brak ORPHAN).
if [ -f "$REGISTRY" ] && [ -d "$DOMAINS_DIR" ]; then
  # shellcheck source=registry.sh
  . "$REGISTRY"
  ORPHAN=0
  ORPHAN_DETAIL=""
  for f in "$DOMAINS_DIR"/*.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .sh)"
    found=0
    for gate_id in $(registry_gate_ids); do
      cmd="$(registry_field "$gate_id" 8)"
      if [ "$cmd" = "tools/verify/gates/domains/$base.sh" ]; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      ORPHAN=$((ORPHAN+1))
      ORPHAN_DETAIL="$ORPHAN_DETAIL $base"
    fi
  done
  if [ "$ORPHAN" -eq 0 ]; then
    pass "INTEG-002 exists→declared (brak ORPHAN)" BLOCKING "Każdy skrypt domains/ ma wpis w registry."
  else
    fail "INTEG-002 exists→declared (brak ORPHAN)" BLOCKING "$ORPHAN ORPHAN (implementacja bez registry):$ORPHAN_DETAIL"
  fi
fi

# ── INTEG-003: getenv/odczyt configu → klucz zdefiniowany (consumed→defined) ──
# Każdy odczyt zmiennej środowiskowej w kodzie musi mieć definicję w .env.example.
if [ -f "$CONFIG_DIR/.env.example" ]; then
  MISSING_ENV=0
  MISSING_ENV_DETAIL=""
  # Szukamy ${VAR} i $VAR w skryptach tools/verify/ i system/control-plane/state/.
  for f in tools/verify/*.sh tools/verify/core/*.sh tools/verify/gates/*.sh tools/verify/gates/domains/*.sh system/control-plane/state/*.sh; do
    [ -f "$f" ] || continue
    # Wyciągamy nazwy zmiennych używanych w kodzie (${VAR} lub $VAR).
    while IFS= read -r var; do
      [ -z "$var" ] && continue
      # Pomijamy zmienne bashowe/systemowe i te zdefiniowane w lib.sh.
      case "$var" in
        BASH_SOURCE|PWD|HOME|PATH|SHELL|USER|UID|GID|LINENO|FUNCNAME|RANDOM|SECONDS|IFS|OLDPWD|SHLVL|PPID|TERM|LANG|LC_ALL|LC_CTYPE|HOSTNAME|OSTYPE|MACHTYPE|_|0|1|2|3|4|5|6|7|8|9|'*'|'@'|'#'|'?'|'!'|'$'|'-')
          continue ;;
      esac
      # Sprawdzamy czy zmienna jest zdefiniowana w .env.example.
      if ! grep -qE "^[[:space:]]*${var}=" "$CONFIG_DIR/.env.example" 2>/dev/null; then
        # Pomijamy zmienne zdefiniowane w lib.sh (STATE_DIR, STATE_DB, itd.)
        if ! grep -qE "^[[:space:]]*${var}=" tools/verify/core/lib.sh system/control-plane/state/lib.sh 2>/dev/null; then
          MISSING_ENV=$((MISSING_ENV+1))
          MISSING_ENV_DETAIL="$MISSING_ENV_DETAIL ${var}($(basename "$f"))"
        fi
      fi
    done < <(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null | sed 's/^\${//; s/}$//; s/^\$//' | sort -u)
  done
  if [ "$MISSING_ENV" -eq 0 ]; then
    pass "INTEG-003 consumed→defined (env vars)" BLOCKING "Każda zmienna środowiskowa używana w kodzie ma definicję."
  else
    fail "INTEG-003 consumed→defined (env vars)" BLOCKING "$MISSING_ENV zmiennych bez definicji:$MISSING_ENV_DETAIL"
  fi
else
  info "INTEG-003 consumed→defined (env vars)" "Brak config/.env.example — pomijam (nie jest wymagany w tym repo)."
fi

# ── INTEG-004: klucz zdefiniowany → ma konsumenta (defined→consumed) ──
# Każdy klucz w .env.example musi być używany w kodzie (brak martwej zmiennej).
if [ -f "$CONFIG_DIR/.env.example" ]; then
  DEAD_ENV=0
  DEAD_ENV_DETAIL=""
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    # Szukamy konsumenta w kodzie.
    if ! grep -rqE "\$\{${key}\}|\$${key}" tools/verify/ system/control-plane/state/ 2>/dev/null; then
      DEAD_ENV=$((DEAD_ENV+1))
      DEAD_ENV_DETAIL="$DEAD_ENV_DETAIL $key"
    fi
  done < <(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$CONFIG_DIR/.env.example" 2>/dev/null | sed 's/^[[:space:]]*//; s/=$//' | sort -u)
  if [ "$DEAD_ENV" -eq 0 ]; then
    pass "INTEG-004 defined→consumed (env vars)" BLOCKING "Każdy klucz w .env.example ma konsumenta w kodzie."
  else
    fail "INTEG-004 defined→consumed (env vars)" BLOCKING "$DEAD_ENV martwych kluczy (zdefiniowane bez konsumenta):$DEAD_ENV_DETAIL"
  fi
else
  info "INTEG-004 defined→consumed (env vars)" "Brak config/.env.example — pomijam."
fi

# ── INTEG-005: każdy moduł verify pisze evidence (runtime completeness) ──
# Każdy gate IMPLEMENTED (nie PROPOSED) musi mieć plik evidence.
# Wyjątek bootstrap: evidence.sh generuje evidence PO uruchomieniu każdego
# gate'a, a meta-gate'y są uruchamiane NA KOŃCU (po wygenerowaniu evidence
# dla wszystkich innych). W momencie wykonania tego skryptu ich evidence
# jeszcze nie istnieje — to uzasadniona samo-referencja (bootstrap), nie brak
# evidence.
#   - GATE-038: ten gate — jego evidence generuje evidence.sh PO tym przebiegu.
#   - GATE-001: meta-gate — evidence.sh uruchamia go NA KOŃCU.
#   - GATE-020: meta-gate (EVIDENCE) — evidence.sh uruchamia go NA KOŃCU.
if [ -f "$REGISTRY" ] && [ -d "$EVIDENCE_DIR" ]; then
  # shellcheck source=registry.sh
  . "$REGISTRY"
  MISSING_EVIDENCE=0
  MISSING_EVIDENCE_DETAIL=""
  for gate_id in $(registry_gate_ids); do
    status="$(registry_field "$gate_id" 22)"
    if [ "$status" = "PROPOSED" ]; then
      continue
    fi
    # Bootstrap: meta-gate'y, których evidence generuje evidence.sh PO bieżącym
    # przebiegu (self + meta-gate'y uruchamiane na końcu).
    if [ "$gate_id" = "GATE-038" ] || [ "$gate_id" = "GATE-001" ] || [ "$gate_id" = "GATE-020" ]; then
      continue
    fi
    if [ ! -f "$EVIDENCE_DIR/$gate_id.evidence" ]; then
      MISSING_EVIDENCE=$((MISSING_EVIDENCE+1))
      MISSING_EVIDENCE_DETAIL="$MISSING_EVIDENCE_DETAIL $gate_id"
    fi
  done
  if [ "$MISSING_EVIDENCE" -eq 0 ]; then
    pass "INTEG-005 runtime completeness (evidence)" BLOCKING "Każdy gate IMPLEMENTED ma evidence wykonania."
  else
    fail "INTEG-005 runtime completeness (evidence)" BLOCKING "$MISSING_EVIDENCE gate'ów bez evidence:$MISSING_EVIDENCE_DETAIL"
  fi
fi

# ── INTEG-006: tabela w schemacie → używana (defined→consumed) ──
# Każda tabela w migracjach SQL musi być używana (INSERT/SELECT) w kodzie.
# Wyjątek: tabele oznaczone jako RESERVED_TABLES (declared-intent) w nagłówku
# migracji — część pełnego domain model, zdefiniowane z wyprzedzeniem
# (forward-compatible schema), konsumowane inkrementalnie. To udokumentowana
# rezerwacja, nie martwy kod.
if [ -d "$MIGRATIONS_DIR" ]; then
  DEAD_TABLE=0
  DEAD_TABLE_DETAIL=""
  # Zbieramy tabele zadeklarowane jako reserved (declared-intent) w migracjach.
  RESERVED_TABLES="$(grep -hoE '^--[[:space:]]*RESERVED_TABLES:[[:space:]].*' "$MIGRATIONS_DIR"/*.sql 2>/dev/null | sed 's/^--[[:space:]]*RESERVED_TABLES:[[:space:]]*//' | tr '\n' ' ')"
  for sql in "$MIGRATIONS_DIR"/*.sql; do
    [ -f "$sql" ] || continue
    while IFS= read -r table; do
      [ -z "$table" ] && continue
      # Tabele reserved (declared-intent) są świadomie zdefiniowane bez użycia.
      if printf '%s\n' $RESERVED_TABLES | grep -qx "$table"; then
        continue
      fi
      # Szukamy użycia tabeli w kodzie (INSERT/SELECT/UPDATE/DELETE INTO/FROM).
      if ! grep -rqE "(INSERT[[:space:]]+INTO|SELECT[[:space:]]+.*FROM|UPDATE|DELETE[[:space:]]+FROM)[[:space:]]+${table}" system/control-plane/state/ tools/verify/ 2>/dev/null; then
        DEAD_TABLE=$((DEAD_TABLE+1))
        DEAD_TABLE_DETAIL="$DEAD_TABLE_DETAIL $table"
      fi
    done < <(grep -oE 'CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*' "$sql" 2>/dev/null | awk '{print $NF}')
  done
  if [ "$DEAD_TABLE" -eq 0 ]; then
    pass "INTEG-006 defined→consumed (tabele SQL)" BLOCKING "Każda tabela w migracjach jest używana w kodzie."
  else
    fail "INTEG-006 defined→consumed (tabele SQL)" BLOCKING "$DEAD_TABLE martwych tabel (zdefiniowane bez użycia):$DEAD_TABLE_DETAIL"
  fi
fi

# ── INTEG-007: ścieżka w docs → istnieje w repo (docs→fs) ──
# Każda ścieżka/plik wymieniony w docs/00-foundation musi istnieć.
if [ -d "$DOCS_DIR/00-foundation" ]; then
  MISSING_DOC_PATH=0
  MISSING_DOC_PATH_DETAIL=""
  for doc in "$DOCS_DIR"/00-foundation/*.md; do
    [ -f "$doc" ] || continue
    # Wyciągamy ścieżki w backtickach lub nawiasach (ścieżki plików/katalogów).
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      # Pomijamy ścieżki zewnętrzne (http, /etc, /opt, ~, itd.) i wzorce.
      case "$path" in
        http*|https*|/etc/*|/opt/*|/usr/*|/var/*|~/*|*/*/*/*/*/*|*.md|*.yaml|*.yml|*.json|*.toml|*.sql)
          # Sprawdzamy tylko ścieżki względne repo (bez wiodącego /).
          if [[ "$path" != /* ]] && [[ "$path" != http* ]] && [[ "$path" != ~* ]]; then
            # Ścieżka istnieje bezpośrednio (względna ścieżka repo).
            if [ -e "$path" ]; then
              continue
            fi
            # Bare filename (bez '/') — sprawdzamy czy istnieje GDZIEKOLWIEK w repo
            # (np. docs odwołują się do `secret-scan.sh`, a plik jest w tools/security/).
            if [[ "$path" != */* ]]; then
              if find . -path ./.git -prune -o -name "$path" -print -quit 2>/dev/null | grep -q .; then
                continue
              fi
            fi
            MISSING_DOC_PATH=$((MISSING_DOC_PATH+1))
            MISSING_DOC_PATH_DETAIL="$MISSING_DOC_PATH_DETAIL $path"
          fi
          ;;
      esac
    done < <(grep -oE '`[^`]+`' "$doc" 2>/dev/null | tr -d '`' | sort -u)
  done
  if [ "$MISSING_DOC_PATH" -eq 0 ]; then
    pass "INTEG-007 docs→fs (ścieżki w docs)" BLOCKING "Każda ścieżka wymieniona w docs/00-foundation istnieje."
  else
    fail "INTEG-007 docs→fs (ścieżki w docs)" BLOCKING "$MISSING_DOC_PATH ścieżek z docs bez odpowiednika w repo:$MISSING_DOC_PATH_DETAIL"
  fi
else
  info "INTEG-007 docs→fs (ścieżki w docs)" "Brak docs/00-foundation — pomijam."
fi

# ── INTEG-008: katalog wymagany przez konstytucję → istnieje (contract→fs) ──
# Wymagane katalogi top-level muszą istnieć.
REQUIRED_DIRS=(
  "tools/verify"
  "system/control-plane/state"
  "config"
  "artifacts"
  "docs"
  ".github/workflows"
  ".git-hooks"
)
MISSING_DIRS=""
for d in "${REQUIRED_DIRS[@]}"; do
  if [ ! -d "./$d" ]; then
    MISSING_DIRS="$MISSING_DIRS $d"
  fi
done
if [ -z "$MISSING_DIRS" ]; then
  pass "INTEG-008 contract→fs (wymagane katalogi)" BLOCKING "Wszystkie wymagane katalogi istnieją."
else
  fail "INTEG-008 contract→fs (wymagane katalogi)" BLOCKING "Brak wymaganych katalogów:$MISSING_DIRS"
fi

# ── INTEG-009: skrypt w repo → wywoływany (exists→wired) ──
# Każdy skrypt w tools/verify/ musi być wywoływany (CI/hook/inny skrypt).
# Wykluczamy skrypty domen (są wywoływane przez enforcement.sh) i testy.
# Entry pointy (verify.sh, enforcement.sh, evidence.sh, profile.sh, report.sh,
# gate-integrity.sh, state.sh) są z definicji podpięte — są korzeniami grafu wywołań.
ENTRY_POINTS="tools/verify/verify.sh system/control-plane/state/state.sh tools/verify/gates/enforcement.sh tools/verify/gates/profile.sh tools/verify/gates/gate-integrity.sh tools/verify/gates/evidence.sh tools/verify/gates/report.sh"
UNWIRED_SCRIPT=0
UNWIRED_SCRIPT_DETAIL=""
for f in tools/verify/*.sh tools/verify/core/*.sh tools/verify/gates/*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
# ADNOTACJA AUDYT-GATES-PIPELINES 2026-08-20 (drift #14): wykluczenie testow/runnerow CELOWE, ale komentarz 'osiagalne przez run_tests.sh' nieaktualny (runner dangling, zero live callerow). Komentarz zaktualizowany, plik bez zmian funkcjonalnych.
  # Pomijamy skrypty domen (wywoływane przez enforcement.sh) i testy.
  case "$base" in
    *.test.sh|test_*.sh|run_tests.sh)
      continue ;;
  esac
  # Entry point jest z definicji podpięty (jest korzeniem grafu wywołań).
  if printf '%s\n' "$ENTRY_POINTS" | grep -qx "$f"; then
    continue
  fi
  # Sprawdzamy czy skrypt jest wywoływany gdziekolwiek (CI, hooks, verify.sh, enforcement.sh,
  # oraz inne skrypty gates/ — np. evidence.sh source'uje registry.sh).
  # Dopasowujemy zarówno wywołania (bash/source/.) jak i referencje po nazwie
  # (np. REGISTRY="$GATES_DIR/registry.sh" w enforcement.sh/profile.sh/evidence.sh).
  if ! grep -rqE "(bash|sh|source|\.)[[:space:]]+[^#]*${base}|${base}" .github/workflows/ .git-hooks/ tools/verify/verify.sh tools/verify/gates/enforcement.sh tools/verify/gates/profile.sh tools/verify/gates/*.sh tools/verify/core/profiles.sh tools/verify/core/lib.sh 2>/dev/null; then
    # Pomijamy skrypty domen — są wywoływane przez enforcement.sh przez registry (command field).
    if [[ "$f" == tools/verify/gates/domains/* ]]; then
      continue
    fi
    UNWIRED_SCRIPT=$((UNWIRED_SCRIPT+1))
    UNWIRED_SCRIPT_DETAIL="$UNWIRED_SCRIPT_DETAIL $base"
  fi
done
if [ "$UNWIRED_SCRIPT" -eq 0 ]; then
  pass "INTEG-009 exists→wired (skrypty wywoływane)" BLOCKING "Każdy skrypt tools/verify/ jest wywoływany (CI/hook/verify.sh)."
else
  fail "INTEG-009 exists→wired (skrypty wywoływane)" BLOCKING "$UNWIRED_SCRIPT niepodpiętych skryptów:$UNWIRED_SCRIPT_DETAIL"
fi

# ── INTEG-010: check_id w kodzie → w rejestrze (declared→registered) ──
# Każdy check_id (np. INTEG-xxx, GATE-xxx, STRUCTURE-xxx) użyty w kodzie
# musi mieć wpis w registry (lub być zdefiniowany w skrypcie domeny).
if [ -f "$REGISTRY" ]; then
  # shellcheck source=registry.sh
  . "$REGISTRY"
  UNREGISTERED_ID=0
  UNREGISTERED_ID_DETAIL=""
  # Zbieramy wszystkie zarejestrowane gate_id.
  REGISTERED_IDS="$(registry_gate_ids)"
  # Szukamy check_id w skryptach domen (wzorzec: "PASS-xxx" lub "FAIL-xxx").
  for f in "$DOMAINS_DIR"/*.sh; do
    [ -f "$f" ] || continue
    while IFS= read -r cid; do
      [ -z "$cid" ] && continue
      # Sprawdzamy czy check_id jest zarejestrowany (jako gate_id) lub
      # jest wewnętrznym checkiem domeny (wzorzec DOMAIN-NNN).
      if ! printf '%s\n' "$REGISTERED_IDS" | grep -qx "$cid"; then
        # Wewnętrzne checki domen (np. STRUCTURE-001) są legalne — mają
        # prefiks nazwy domeny. Sprawdzamy czy prefiks odpowiada domenie.
        domain_prefix="$(printf '%s' "$cid" | cut -d- -f1)"
        # Jeśli check_id ma format DOMAIN-NNN, jest legalny (wewnętrzny check domeny).
        if ! printf '%s' "$cid" | grep -qE '^[A-Z]+-[0-9]{3}$'; then
          UNREGISTERED_ID=$((UNREGISTERED_ID+1))
          UNREGISTERED_ID_DETAIL="$UNREGISTERED_ID_DETAIL $cid($(basename "$f"))"
        fi
      fi
    done < <(grep -oE '(pass|fail|info)[[:space:]]+"[A-Z]+-[0-9]{3}' "$f" 2>/dev/null | grep -oE '[A-Z]+-[0-9]{3}' | sort -u)
  done
  if [ "$UNREGISTERED_ID" -eq 0 ]; then
    pass "INTEG-010 declared→registered (check_id)" BLOCKING "Każdy check_id w kodzie jest zarejestrowany lub jest wewnętrznym checkiem domeny."
  else
    fail "INTEG-010 declared→registered (check_id)" BLOCKING "$UNREGISTERED_ID niezarejestrowanych check_id:$UNREGISTERED_ID_DETAIL"
  fi
fi

# ── INTEG-011: migracja ↔ wpis, bez dziur w sekwencji (spójność wersji) ──
# Migracje muszą być sekwencyjne (0001, 0002, ...) bez dziur.
if [ -d "$MIGRATIONS_DIR" ]; then
  GAP_MIGRATION=0
  GAP_MIGRATION_DETAIL=""
  # Zbieramy numery migracji.
  MIG_NUMS="$(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | grep -oE '[0-9]{4}' | sort -n)"
  EXPECTED=1
  for num in $MIG_NUMS; do
    if [ "$num" -ne "$EXPECTED" ]; then
      GAP_MIGRATION=$((GAP_MIGRATION+1))
      GAP_MIGRATION_DETAIL="$GAP_MIGRATION_DETAIL (oczekiwano $EXPECTED, jest $num)"
    fi
    EXPECTED=$((EXPECTED+1))
  done
  if [ "$GAP_MIGRATION" -eq 0 ]; then
    pass "INTEG-011 spójność migracji (bez dziur)" BLOCKING "Migracje są sekwencyjne bez dziur."
  else
    fail "INTEG-011 spójność migracji (bez dziur)" BLOCKING "$GAP_MIGRATION dziur w sekwencji migracji:$GAP_MIGRATION_DETAIL"
  fi
fi

# ── INTEG-012: plik źródłowy osiągalny z entry pointów (orphan detection) ──
# Każdy plik .sh w tools/verify/ i system/control-plane/state/ musi być
# osiągalny z entry pointów (verify.sh, state.sh, enforcement.sh, hooks, CI).
# Wykluczamy testy (są osiągalne przez run_tests.sh) i skrypty domen.
ORPHAN_FILE=0
ORPHAN_FILE_DETAIL=""
ENTRY_POINTS="tools/verify/verify.sh system/control-plane/state/state.sh tools/verify/gates/enforcement.sh tools/verify/gates/profile.sh tools/verify/gates/gate-integrity.sh tools/verify/gates/evidence.sh tools/verify/gates/report.sh"
for f in tools/verify/*.sh tools/verify/core/*.sh tools/verify/gates/*.sh tools/verify/gates/domains/*.sh system/control-plane/state/*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
# ADNOTACJA AUDYT-GATES-PIPELINES 2026-08-20 (drift #14): wykluczenie testow/runnerow CELOWE, ale komentarz 'osiagalne przez run_tests.sh' nieaktualny (runner dangling, zero live callerow). Komentarz zaktualizowany, plik bez zmian funkcjonalnych.
  # Pomijamy testy (osiągalne przez run_tests.sh) i skrypty domen (osiągalne przez enforcement.sh).
  case "$base" in
    test_*.sh|run_tests.sh)
      continue ;;
  esac
  if [[ "$f" == tools/verify/gates/domains/* ]]; then
    continue
  fi
  # Entry point jest z definicji osiągalny (jest korzeniem grafu wywołań).
  if printf '%s\n' "$ENTRY_POINTS" | grep -qx "$f"; then
    continue
  fi
  # Sprawdzamy czy plik jest osiągalny z entry pointów (source/import/bash).
  REACHABLE=0
  for ep in $ENTRY_POINTS tools/verify/core/profiles.sh tools/verify/core/lib.sh; do
    if [ -f "$ep" ] && grep -qE "(source|\.)[[:space:]]+.*${base}|bash[[:space:]]+.*${base}" "$ep" 2>/dev/null; then
      REACHABLE=1
      break
    fi
  done
  # Sprawdzamy też czy jest osiągalny z CI/hooks oraz z innych skryptów gates/
  # (np. evidence.sh source'uje registry.sh, invariant-engine.sh source'uje registry.sh).
  if [ "$REACHABLE" -eq 0 ]; then
    if grep -rqE "${base}" .github/workflows/ .git-hooks/ tools/verify/gates/*.sh tools/verify/core/profiles.sh tools/verify/core/lib.sh 2>/dev/null; then
      REACHABLE=1
    fi
  fi
  if [ "$REACHABLE" -eq 0 ]; then
    ORPHAN_FILE=$((ORPHAN_FILE+1))
    ORPHAN_FILE_DETAIL="$ORPHAN_FILE_DETAIL $base"
  fi
done
if [ "$ORPHAN_FILE" -eq 0 ]; then
  pass "INTEG-012 orphan detection (osiągalność)" BLOCKING "Każdy plik źródłowy jest osiągalny z entry pointów."
else
  fail "INTEG-012 orphan detection (osiągalność)" BLOCKING "$ORPHAN_FILE nieosiągalnych plików:$ORPHAN_FILE_DETAIL"
fi

verify_module_exit
