#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  gates/domains/agent-egress-discipline.sh — GATE-140
#  LAW-EGRESS-2 (brama, nie port) + LAW-EGRESS-3 (tło wymaga weryfikacji)
#
#  POWÓD ISTNIENIA (ZMIERZONE 2026-09-30, dwa realne zdarzenia):
#   [1] Agent robiący baseline AIOS odpalił skrypt idący WPROST na :11434
#       (Ollama), omijając bramę :38080 (billing/evidence/gate). Kanon
#       (SSOT prompt) mówi „NIGDY bezpośrednio na :14008, :7000 ani :11434",
#       ale żadna bramka tego nie MIERZYŁA — zakaz był prozą.
#   [2] Ten sam agent odpalił `nohup … > baseline.log 2>&1 &`, po 3 s zobaczył
#       PUSTY plik i uznał to za „uruchomione w tle". Proces zginął natychmiast
#       (exit 1). Pusty log potraktowany jako sukces = brak pomiaru.
#
#  CO MIERZY (nie deklaruje):
#   EG-001  SSOT prawa istnieje i wskazuje tę bramkę
#   EG-002  zakaz JEST w prompcie rozsyłanym do agentów (marker + brama)
#   EG-003  brak WYWOŁANIA MODELU wprost na :11434/:7000/:14008 w skanie
#   EG-004  brak `nohup` bez kontroli życia/kodu wyjścia w tym samym pliku
#   EG-005  ratchet długu (tryb --all) / zapis baseline
#   EG-006  raport pokrycia
#
#  TRYBY:
#   (bez arg)      change-aware — TYLKO DODANE LINIE staged/ostatniego commita,
#                  i tylko w obrębie powierzchni agenta. Nie da się WPROWADZIĆ
#                  nowego naruszenia; dług zastany nie blokuje cudzej pracy.
#   --all          pełny skan powierzchni agenta; raport długu + RATCHET
#                  (config/canonical/agent-egress-baseline.yaml) — dług nie
#                  może WZROSNĄĆ.
#   --update-baseline  pełny skan i zapis zmierzonego długu jako baseline.
#   <file|dir>...  skan jawnego zakresu (testy negatywne/dodatnie).
#
#  WYDAJNOŚĆ (zmierzone 2026-09-30, WAŻNE dla bramki pre-commit):
#   - skan opiera się na POJEDYNCZYCH przebiegach `rg` (nie fork na plik/linie);
#     wersja „awk per plik" na drzewie ~7 tys. plików nie kończyła się w minutach,
#     a bramka, która „wisi", jest sama w sobie defektem.
#   - EG-002 czyta SUROWY SSOT przez `grep -F`, nie przez pyyaml:
#     `yaml.safe_load(config/agent-models.yaml)` (735 KB) trwa >20 s.
#   - allowlista jest preloadowana do tablicy i dopasowywana przez `[[ =~ ]]`.
#
#  Kontrakt hook-runnera / verify: exit 0 = PASS/WARN, exit 1 = FAIL.
#  Wyjątki (cytaty zakazu, dokumentacja historyczna, instrumenty mierzące lane):
#     tools/verify/gates/agent-egress-allowlist.txt
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

SSOT="$ROOT/config/canonical/agent-egress-discipline.yaml"
BASELINE="$ROOT/config/canonical/agent-egress-baseline.yaml"
ALLOWLIST="${AGENT_EGRESS_ALLOWLIST:-$ROOT/tools/verify/gates/agent-egress-allowlist.txt}"
PROMPT_YAML="$ROOT/config/agent-models.yaml"
MARKER="NIGDY bezpośrednio na"

# Powierzchnia agenta — gdzie wzorzec zmienia ZACHOWANIE agenta.
SURFACE_GLOB='\.(sh|md|py|yaml|yml|sl|slurm|txt)$'
# UWAGA: `rg -g` to GLOB, nie regex. `-g '*.sh'` działa; `-g '\.(sh|md)$'` NIE
# (regex podany jako glob => 0 plików => fałszywy PASS). Zmierzone 2026-09-30.
RG_GLOBS=(--glob '*.sh' --glob '*.md' --glob '*.py' --glob '*.yaml' --glob '*.yml' --glob '*.sl' --glob '*.slurm' --glob '*.txt')
SURFACE_TOP='^(skills|scripts|tools/gates|tools/verify/gates|config/canonical|products/akceleratory)/'
SURFACE_DIRS=(skills scripts tools/gates tools/verify/gates config/canonical products/akceleratory)

say "=== GATE-140 AGENT-EGRESS-DISCIPLINE (LAW-EGRESS-2/3) ==="

# ── Wzorce (ERE) ──────────────────────────────────────────────────────────
CLIENT_RE='(curl|wget|http://|https://|requests\.|httpx\.|urllib|openai|fetch\()'
PORT_RE=':11434|:7000|:14008'
MODEL_RE='/api/chat|/api/generate|/api/create|/api/pull|/api/embeddings|/v1/chat|/v1/complete|/v1/messages|/v1/models|/api/v1/chat|/api/v1/diffuse|/api/v1/inference|/api/v1/completions|/api/v1/generate'
INFO_RE='/api/tags|/api/ps|/health|/healthz|/metrics|/mesh'
VERIFY_RE='pgrep|kill -0|\$!|\bwait\b|test -f|test -s|\[ -s |\[ -f |ss -ltnp|is-active|compose ps|systemctl status|rc=\$|\$\?|--check'

# ── 0. Tryb ───────────────────────────────────────────────────────────────
MODE="changed"
EXPLICIT=()
for a in "$@"; do
  case "$a" in
    --all) MODE="all" ;;
    --update-baseline) MODE="update-baseline" ;;
    --help|-h)
      say "użycie: agent-egress-discipline.sh [--all|--update-baseline|<plik|katalog>...]"
      exit 0 ;;
    *) MODE="explicit"; EXPLICIT+=("$a") ;;
  esac
done

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
CAND="$TMP/cand"; FILESET="$TMP/files"
: > "$CAND"; : > "$FILESET"

skip_path() {
  case "$1" in
    .qwen/*|node_modules/*|vendor/*|*/vendor/*|target/*|*/target/*|*.bak*|*/reports/*|*/artifacts/*|ledger-backup-*/*) return 0 ;;
  esac
  return 1
}

# ── 1. EG-001: SSOT prawa ─────────────────────────────────────────────────
if [ -r "$SSOT" ]; then
  if grep -q 'LAW-EGRESS-2' "$SSOT" && grep -q 'LAW-EGRESS-3' "$SSOT"; then
    pass "EG-001 SSOT prawa istnieje" BLOCKING "LAW-EGRESS-2/3 w $(basename "$SSOT")"
  else
    fail "EG-001 SSOT prawa istnieje" BLOCKING "brak LAW-EGRESS-2/3 w $SSOT"
  fi
  if grep -q 'tools/verify/gates/domains/agent-egress-discipline.sh' "$SSOT"; then
    pass "EG-001b SSOT wskazuje bramkę" BLOCKING "SSOT → ta bramka"
  else
    fail "EG-001b SSOT wskazuje bramkę" BLOCKING "SSOT nie wskazuje agent-egress-discipline.sh (deklaracja bez bramki = dług)"
  fi
else
  fail "EG-001 SSOT prawa istnieje" BLOCKING "brak $SSOT"
fi

# ── 2. EG-002: zakaz w prompcie rozsyłanym do agentów ─────────────────────
# POMIAR: grep po SUROWYM pliku SSOT, NIE pyyaml. Zmierzone 2026-09-30:
# `yaml.safe_load(config/agent-models.yaml)` (735 KB) trwa >20 s — bramka
# pre-commit NIE MOŻE wieszać commita na parserze YAML. Marka zakazu i porty
# są literałami w bloku `system_prompt.content`, więc grep mierzy to samo.
if [ -r "$PROMPT_YAML" ]; then
  if grep -qF "$MARKER" "$PROMPT_YAML" 2>/dev/null \
     && grep -qF ':11434' "$PROMPT_YAML" 2>/dev/null \
     && grep -qF ':14008' "$PROMPT_YAML" 2>/dev/null \
     && grep -qF '38080' "$PROMPT_YAML" 2>/dev/null; then
    pass "EG-002 zakaz w prompcie SSOT" BLOCKING "marker '$MARKER' + ':11434'/':14008' + brama '38080'"
  else
    fail "EG-002 zakaz w prompcie SSOT" BLOCKING "prompt SSOT nie zawiera zakazu (marker '$MARKER' + porty + '38080') — agenci go nie dostaną"
  fi
else
  fail "EG-002 zakaz w prompcie SSOT" BLOCKING "brak $PROMPT_YAML"
fi

# ── 3. Zbieranie kandydatów ───────────────────────────────────────────────
SCANNED=0
case "$MODE" in
  changed)
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      # Brak gita = brak pomiaru. Nie wolno orzec PASS bez pomiaru (false-green).
      warn "EG-003 brak pomiaru (tryb changed)" "poza repozytorium git — użyj --all albo podaj pliki jawnie"
      info "EG-006 raport" "tryb=changed; pomiar NIEMOŻLIWY (brak git) — wynik nie jest zaliczeniem zmiany"
      verify_module_exit
    fi
    DIFF="$(git diff --cached -U0 --diff-filter=ACM 2>/dev/null)"
    if [ -z "$DIFF" ]; then
      DIFF="$(git diff -U0 --diff-filter=ACM HEAD~1..HEAD 2>/dev/null)"
    fi
    # Dodane linie w obrębie powierzchni agenta (filtr ścieżki + klient + port).
    # UWAGA: filtr cl/pt MUSI być w tym samym awk — bez niego KAŻDA dodana linia
    # staje się kandydatem (982 zamiast kilku), a klasyfikacja robi setki fork(ów)
    # i bramka pre-commit „wisi" (zmierzone 2026-09-30).
    printf '%s\n' "$DIFF" | awk -v top="$SURFACE_TOP" -v gl="$SURFACE_GLOB" \
        -v cl="$CLIENT_RE" -v pt="$PORT_RE" '
      /^\+\+\+ / { f=substr($0,7); keep=(f ~ top && f ~ gl); next }
      /^\+/ && !/^\+\+\+/ {
        if (keep) {
          line=substr($0,2)
          if (line ~ cl && line ~ pt) printf "%s\t%s\n", f, line
        }
      }' > "$CAND"
    # Lista plików zmienionych (dla EG-004: nohup sprawdzamy na CAŁYM pliku,
    # bo kontrola życia może stać w innej linii niż samo uruchomienie).
    printf '%s\n' "$DIFF" | awk -v top="$SURFACE_TOP" -v gl="$SURFACE_GLOB" '
      /^\+\+\+ / { f=substr($0,7); if (f ~ top && f ~ gl) print f }' | sort -u > "$FILESET"
    SCANNED="$(printf '%s\n' "$DIFF" | awk '/^\+\+\+ /{n++} END{print n+0}')"
    ;;
  all|update-baseline|explicit)
    if [ "$MODE" = "explicit" ]; then
      TARGETS=("${EXPLICIT[@]}")
    else
      TARGETS=("${SURFACE_DIRS[@]}")
    fi
    # Lista plików powierzchni (jedno `rg --files` na katalog).
    for d in "${TARGETS[@]}"; do
      [ -d "$d" ] && rg --files --no-ignore "${RG_GLOBS[@]}" "$d" 2>/dev/null
      [ -f "$d" ] && echo "$d"
    done | sort -u | while IFS= read -r f; do skip_path "$f" && continue; echo "$f"; done > "$FILESET"
    SCANNED="$(sort -u "$FILESET" | wc -l)"
    # Kandydaci: JEDEN przebieg `rg` po całym zakresie + JEDEN filtr portu.
    if [ "${#TARGETS[@]}" -gt 0 ]; then
      # `-H`: rg pomija prefiks ścieżki przy JEDNYM pliku (`2:curl ...`), przez co
      # parser `path:nr:tekst` nie miałby czego rozciąć i CAND byłby pusty
      # (fałszywy PASS w trybie explicit — zmierzone 2026-09-30).
      rg -n -H --no-ignore "${RG_GLOBS[@]}" -e "$CLIENT_RE" "${TARGETS[@]}" 2>/dev/null \
        | grep -E "$PORT_RE" 2>/dev/null \
        | sed -n 's/^\([^:]*\):\([0-9][0-9]*\):/\1\t\2\t/p' > "$CAND"
    fi
    ;;
esac

# ── 4. Allowlista ─────────────────────────────────────────────────────────
# WZORY preloadowane do tablicy + dopasowanie W PROCESIE ([[ =~ ]]).
# Zmierzone 2026-09-30: dopasowanie przez `printf | grep` na wiersz robiło
# O(kandydaci x wzory) fork(ów) i wydłużało bramkę do dziesiątek sekund.
ALLOW_PATTERNS=()
if [ -r "$ALLOWLIST" ]; then
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    case "$_p" in \#*) continue ;; esac
    ALLOW_PATTERNS+=("$_p")
  done < "$ALLOWLIST"
fi
is_allowed() { # <tekst wiersza>
  local p
  [ "${#ALLOW_PATTERNS[@]}" -eq 0 ] && return 1
  for p in "${ALLOW_PATTERNS[@]}"; do
    [[ "$1" =~ $p ]] && return 0
  done
  return 1
}

# ── 4b. Suweren exempt (LAW-Ω) ────────────────────────────────────────────
# Ścieżki autoryzowane przez Suwerena (reins off, KANON 2026-09-07) — wyjęte
# spod EG-003/EG-004 BEZ alertu (tylko licznik audytowy). Czytane z SSOT
# surowym sed (NIE yaml — SSOT ma backticki i nie jest ściśle walidnym YAML).
SOVEREIGN_PATHS=()
if [ -r "$SSOT" ]; then
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    SOVEREIGN_PATHS+=("$_p")
  done < <(sed -n '/^sovereign_exempt:/,/^[a-z]/p' "$SSOT" | grep '^[[:space:]]*-[[:space:]]*"' | sed 's/^[[:space:]]*-[[:space:]]*"//; s/"$//')
fi
SOVEREIGN_COUNT=0
is_sovereign() { # <ścieżka pliku>
  local p
  [ "${#SOVEREIGN_PATHS[@]}" -eq 0 ] && return 1
  for p in "${SOVEREIGN_PATHS[@]}"; do
    [[ "$1" =~ $p ]] && return 0
  done
  return 1
}

# ── 5. Klasyfikacja ───────────────────────────────────────────────────────
BLOCKING_FOUND=0; WARN_FOUND=0
BLOCKING_LIST="$TMP/blocking"; WARN_LIST="$TMP/warn"
: > "$BLOCKING_LIST"; : > "$WARN_LIST"

while IFS= read -r row; do
  [ -z "$row" ] && continue
  f="${row%%	*}"
  rest="${row#*	}"
  skip_path "$f" && continue
  if is_sovereign "$f"; then SOVEREIGN_COUNT=$((SOVEREIGN_COUNT+1)); continue; fi
  is_allowed "$row" && continue
  if printf '%s' "$rest" | grep -Eq "$MODEL_RE"; then
    BLOCKING_FOUND=$((BLOCKING_FOUND+1)); printf '%s: %s\n' "$f" "$rest" >> "$BLOCKING_LIST"
  elif printf '%s' "$rest" | grep -Eq "$INFO_RE"; then
    : # sonda liveness (health/metrics/tags) — poza klasą
  else
    WARN_FOUND=$((WARN_FOUND+1)); printf '%s: %s\n' "$f" "$rest" >> "$WARN_LIST"
  fi
done < "$CAND"

# ── 6. Werdykt EG-003 ─────────────────────────────────────────────────────
# Tryby ścisłe (zmiana/jawny plik) = FAIL na znalezisku. Tryb --all = audyt
# długu: WARN + ratchet (dług zastany nie blokuje, ale nie może rosnąć).
STRICT=0
case "$MODE" in changed|explicit) STRICT=1 ;; esac
if [ "$STRICT" -eq 1 ]; then
  if [ "$BLOCKING_FOUND" -gt 0 ]; then
    fail "EG-003 zakazany endpoint LLM (tryb $MODE)" BLOCKING \
      "$BLOCKING_FOUND wywołanie(a) modelu wprost — do modelu WYŁĄCZNIE przez bramę :38080:"
    sed -n '1,20p' "$BLOCKING_LIST" | sed 's/^/         /'
  else
    pass "EG-003 zakazany endpoint LLM (tryb $MODE)" BLOCKING \
      "brak wywołań wprost na :11434/:7000/:14008 (plików: $SCANNED)"
  fi
else
  if [ "$BLOCKING_FOUND" -gt 0 ]; then
    warn "EG-003 zakazany endpoint LLM (tryb $MODE)" \
      "$BLOCKING_FOUND znalezisk (dług zastany; ratchet pilnuje wzrostu):"
    sed -n '1,25p' "$BLOCKING_LIST" | sed 's/^/         /'
  else
    pass "EG-003 zakazany endpoint LLM (tryb $MODE)" BLOCKING "brak znalezisk (plików: $SCANNED)"
  fi
fi

if [ "$WARN_FOUND" -gt 0 ]; then
  warn "EG-003b bezpośredni dostęp bez wywołania modelu" \
    "$WARN_FOUND trafień — dostęp diagnostyczny wprost; docelowo MCP runtime_*/mesh_*"
fi

# ── 7. EG-004: nohup bez kontroli życia/exit ──────────────────────────────
NOHUP_LIST="$TMP/nohup"; : > "$NOHUP_LIST"
NOHUP_BAD=0
if [ -s "$FILESET" ]; then
  # Dwa przebiegi `rg -l` po CAŁYM zakresie (nie fork na plik) + różnica zbiorów.
  # Kontrola życia może stać w innej linii niż `nohup`, więc decyduje CAŁY plik.
  if [ "$MODE" = "changed" ]; then
    # Tryb zmiany: TYLKO pliki zmienione (delta), inaczej bramka blokowałaby
    # commit cudzym długiem zastanym (zmierzone 2026-09-30 — regresja).
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      skip_path "$f" && continue
      is_sovereign "$f" && continue
      is_allowed "$f" && continue
      # Tylko URUCHOMIENIE (kontekst komendy), nie CYTAT wzorca w komentarzu/prozie.
      # Zmierzone 2026-09-30: bez tego bramka łapała WŁASNĄ dokumentację
      # (config/canonical/gates.yaml, hooks.yaml, baseline) jako naruszenie.
      # UWAGA: kontrola życia liczy się na KAŻDEJ linii (także cytat/baner w `>`),
      # a samo `nohup` tylko w kontekście komendy. Zmierzone 2026-09-30: gdy
      # `next` pomijał linie `#`/`>`, baner korygujący nie był widziany jako
      # dowód kontroli i bramka flagowała WŁASNĄ korektę.
      awk -v vr="$VERIFY_RE" '
        $0 ~ vr { v++ }
        /^[[:space:]]*[#>]/ { next }
        /(^|[;&|][[:space:]]*)(setsid[[:space:]]+)?nohup[[:space:]]/ { n++ }
        END { if (n > 0 && v == 0) print FILENAME }' "$f" > "$TMP/one.hit" 2>/dev/null
      [ -s "$TMP/one.hit" ] || continue
      NOHUP_BAD=$((NOHUP_BAD+1)); echo "$f" >> "$NOHUP_LIST"
    done < "$FILESET"
  else
    # Audyt: dwa przebiegi `rg -l` po CAŁYM zakresie (nie fork na plik) + różnica
    # zbiorów. Kontrola życia może stać w innej linii niż `nohup` — decyduje plik.
    if [ "$MODE" = "explicit" ]; then
      SCAN_TARGETS=("${EXPLICIT[@]}")
    else
      SCAN_TARGETS=("${SURFACE_DIRS[@]}")
    fi
    rg -l --no-ignore "${RG_GLOBS[@]}" -e 'nohup' "${SCAN_TARGETS[@]}" 2>/dev/null | sort -u | while IFS= read -r f; do
      [ -f "$f" ] || continue
      skip_path "$f" && continue
      is_sovereign "$f" && continue
      is_allowed "$f" && continue
      # uruchomienie w kontekście komendy (nie cytat w komentarzu/prozie) ...
      awk '
        /^[[:space:]]*[#>]/ { next }
        /(^|[;&|][[:space:]]*)(setsid[[:space:]]+)?nohup[[:space:]]/ { n++ }
        END { if (n > 0) print FILENAME }' "$f" 2>/dev/null
    done > "$TMP/nohup.cmd"
    # ... i brak jakiejkolwiek kontroli życia/exit w TYM SAMYM pliku
    rg -l --no-ignore "${RG_GLOBS[@]}" -e "$VERIFY_RE" "${SCAN_TARGETS[@]}" 2>/dev/null | sort -u > "$TMP/verify.files"
    comm -23 "$TMP/nohup.cmd" "$TMP/verify.files" > "$TMP/nohup.bad"
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      NOHUP_BAD=$((NOHUP_BAD+1)); echo "$f" >> "$NOHUP_LIST"
    done < "$TMP/nohup.bad"
  fi
fi
if [ "$NOHUP_BAD" -gt 0 ]; then
  if [ "$STRICT" -eq 1 ]; then
    fail "EG-004 nohup bez kontroli życia/exit" BLOCKING \
      "$NOHUP_BAD plik(ów) z 'nohup' bez pgrep/kill -0/\$!/wait/test -f/ss (tło bez dowodu życia):"
    sed -n '1,20p' "$NOHUP_LIST" | sed 's/^/         /'
  else
    warn "EG-004 nohup bez kontroli życia/exit" \
      "$NOHUP_BAD plik(ów) z 'nohup' bez kontroli (dług zastany, tryb $MODE)"
  fi
else
  pass "EG-004 nohup bez kontroli życia/exit" BLOCKING "brak 'nohup' bez weryfikacji w przejrzanym zakresie"
fi

# ── 8. EG-005: ratchet ────────────────────────────────────────────────────
TOTAL=$((BLOCKING_FOUND + NOHUP_BAD))
if [ "$MODE" = "update-baseline" ]; then
  cat > "$BASELINE" <<EOF
# agent-egress-baseline.yaml — RATCHET długu LAW-EGRESS-2/3 (GATE-140)
# Wygenerowane: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Nie edytuj ręcznie — patrz gate: tools/verify/gates/domains/agent-egress-discipline.sh
bypass: $BLOCKING_FOUND
nohup_unverified: $NOHUP_BAD
total: $TOTAL
EOF
  pass "EG-005 baseline zapisany" BLOCKING "$BASELINE (bypass=$BLOCKING_FOUND nohup=$NOHUP_BAD total=$TOTAL)"
elif [ "$MODE" = "all" ] && [ -r "$BASELINE" ]; then
  BASE_TOTAL="$(sed -n 's/^total:[[:space:]]*//p' "$BASELINE" | head -1)"
  if [ -n "$BASE_TOTAL" ] && [ "$TOTAL" -gt "$BASE_TOTAL" ] 2>/dev/null; then
    fail "EG-005 ratchet długu" BLOCKING "dług WZRÓSŁ: $TOTAL > baseline $BASE_TOTAL (bypass=$BLOCKING_FOUND nohup=$NOHUP_BAD)"
  else
    pass "EG-005 ratchet długu" BLOCKING "dług $TOTAL <= baseline ${BASE_TOTAL:-?} (monotoniczny)"
    if [ -n "$BASE_TOTAL" ] && [ "$TOTAL" -lt "$BASE_TOTAL" ] 2>/dev/null; then
      info "EG-005b dług spadł" "odśwież baseline: bash $0 --update-baseline"
    fi
  fi
fi

info "EG-006 raport" "tryb=$MODE plików=$SCANNED; bypass=$BLOCKING_FOUND; sondy(warn)=$WARN_FOUND; nohup_bez_kontroli=$NOHUP_BAD; sovereign_exempt=$SOVEREIGN_COUNT"

verify_module_exit
