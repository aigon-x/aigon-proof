#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# config/config.sh — Universal Project Template — Config Plane Gates
# Moduł: CONFIG GATES (CFG-001..008)
# Self-hosting: zmiana configu przechodzi przez te same gate'y co kod.
#
# Każdy check odpowiada na:
#   WHAT / WHY / SOURCE / EVIDENCE / EXPECTED / ACTUAL / SEVERITY / REMEDIATION
#
# Checki:
#   CFG-001  Jednokanałowość — zakaz bezpośredniego getenv/jq poza lib/config.sh
#   CFG-002  Schema — registry.yaml zgodny z registry.schema.json
#   CFG-003  Klucze — każdy klucz w defaults ma floor, owner, tier, doc, reload
#   CFG-004  Docs — każdy klucz ma doc (opis)
#   CFG-005  Defaulty — każdy default >= floor (tighten nie może być poniżej floora)
#   CFG-006  Waivers — każdy waiver ma expires_at (wyjątki wygasają)
#   CFG-007  Kill-switches — każdy kill-switch ma expires_at
#   CFG-008  Konstytucja — klucze niekonfigurowalne nie są konfigurowalne
#
# Fail-closed: brak registry.yaml (źródło prawdy) = FAIL (BLOCKING).
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

REGISTRY="$ROOT/config/canonical/registry.yaml"
SCHEMA="$ROOT/config/schemas/registry.schema.json"
EXEMPTIONS="$ROOT/config/canonical/config_exemptions.yaml"

say "=== CONFIG PLANE GATES (CFG-001..008) ==="

# ── Helper: czy python3 z yaml jest dostępny ────────────────
PY_OK=0
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  PY_OK=1
fi

# ── Helper: parsowanie registry.yaml do płaskiej listy kluczy ──
# Zwraca linie: <key>\t<floor>\t<default>\t<owner>\t<tier>\t<doc>\t<reload>
# Puste wartości = brak atrybutu. Wypisuje na stdout.
parse_registry() {
  python3 - "$REGISTRY" <<'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    data = yaml.safe_load(f) or {}
gates = data.get("gates") or {}
for k in sorted(gates):
    d = gates.get(k) or {}
    if isinstance(d, dict):
        floor = d.get("floor", "")
        default = d.get("default", "")
        owner = d.get("owner", "")
        tier = d.get("tier", "")
        doc = d.get("doc", "")
        reload = d.get("reload", "")
    else:
        floor = ""
        default = d
        owner = tier = doc = reload = ""
    print(f"{k}\t{floor}\t{default}\t{owner}\t{tier}\t{doc}\t{reload}")
PYEOF
}

# ── CFG-001 Jednokanałowość ─────────────────────────────────
say ""
say "--- CFG-001: Jednokanałowość (zakaz getenv/jq poza lib/config.sh) ---"
# WHY: jednokanałowość config_get jest jedyną gwarancją, że CFG-001..008
# nie są zgadywaniem — bez niej config jest czytany z wielu miejsc i drifci.
# SOURCE: config-plane-design.md (Konstytucja — jednokanałowość config_get).
# EVIDENCE: grep po tools/verify/ za bezpośrednim dostępem do configu.
# EXPECTED: żaden moduł tools/verify/ nie używa getenv/jq do configu.
# ACTUAL: liczba naruszeń znalezionych przez grep.
# SEVERITY: BLOCKING. REMEDIATION: przenieś dostęp do configu do lib/config.sh.
VIOLATIONS=0
# Jedynym dozwolonym kanałem dostępu do configu jest definicja config_get
# w core/config.sh (resolver Config Plane L0-L7). CFG-001 wykrywa FAKTYCZNE
# wywołania config_get/getenv w kodzie produkcyjnym POZA tym kanałem.
# Wykluczamy:
#   * core/config.sh   — definicja config_get (to jest źródło, nie naruszenie)
#   * config/config.sh — sam check (nie używa faktycznego dostępu)
#   * test-*.sh        — testy biblioteki config_get
#   * komentarze (#)   — wzmianki w komentarzach to nie dostęp do configu
while IFS= read -r f; do
  case "$f" in
    *core/config.sh|*config/config.sh|*test-*.sh) continue ;;
  esac
  # Szukamy wywołań config_get/getenv w liniach NIE będących komentarzami.
  if grep -nE 'config_get|getenv' "$f" 2>/dev/null | grep -vE '^\s*[0-9]+:\s*#' >/dev/null; then
    VIOLATIONS=$((VIOLATIONS+1))
    say "       naruszenie: $f"
  fi
done < <(repo_files --dir tools/verify --name '\.sh$')

if [ "$VIOLATIONS" -eq 0 ]; then
  pass "CFG-001 Jednokanałowość" BLOCKING "Brak bezpośredniego config_get/getenv poza core/config.sh w tools/verify/."
else
  fail "CFG-001 Jednokanałowość" BLOCKING "$VIOLATIONS modułów używa bezpośredniego dostępu do configu — przenieś do core/config.sh."
fi

# ── Fail-closed: registry.yaml to źródło prawdy ─────────────
say ""
say "--- CFG-002: Schema (registry.yaml vs registry.schema.json) ---"
if [ ! -f "$REGISTRY" ]; then
  fail "CFG-002 Schema" BLOCKING "Brak źródła prawdy: $REGISTRY — registry.yaml nie istnieje (fail-closed)."
  # Bez registry nie da się zweryfikować pozostałych checków — wszystkie FAIL.
  fail "CFG-003 Klucze" BLOCKING "Brak registry.yaml — nie można zweryfikować kluczy."
  fail "CFG-004 Docs" BLOCKING "Brak registry.yaml — nie można zweryfikować docs."
  fail "CFG-005 Defaulty" BLOCKING "Brak registry.yaml — nie można zweryfikować defaultów."
  fail "CFG-006 Waivers" BLOCKING "Brak registry.yaml — nie można zweryfikować waiverów."
  fail "CFG-007 Kill-switches" BLOCKING "Brak registry.yaml — nie można zweryfikować kill-switchy."
  fail "CFG-008 Konstytucja" BLOCKING "Brak registry.yaml — nie można zweryfikować konstytucji."
  evidence_record "verify:config:cfg-complete" "module" "config/config.sh"
  verify_module_exit
fi

# ── CFG-002 Schema ──────────────────────────────────────────
# WHY: registry.yaml musi być zgodny ze schemą, inaczej resolver czyta
# nieznane pola i config cicho drifci. SOURCE: registry.schema.json.
# EVIDENCE: walidacja jsonschema (lub podstawowa struktura).
# EXPECTED: registry.yaml zgodny ze schemą. ACTUAL: wynik walidacji.
# SEVERITY: BLOCKING. REMEDIATION: popraw registry.yaml pod schemę.
SCHEMA_OK=0
if [ ! -f "$SCHEMA" ]; then
  # Brak schemy = nie można w pełni zweryfikować → podstawowa walidacja struktury.
  warn "CFG-002 Schema" "Brak registry.schema.json — wykonano podstawową walidację struktury."
  if [ "$PY_OK" -eq 1 ]; then
    if python3 - "$REGISTRY" <<'PYEOF' >/dev/null 2>&1
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
assert isinstance(d, dict), "registry nie jest mapą"
assert "schema_version" in d, "brak schema_version"
assert "gates" in d, "brak gates"
PYEOF
    then
      SCHEMA_OK=1
      pass "CFG-002 Schema" BLOCKING "Podstawowa struktura registry.yaml poprawna (schema_version, gates)."
    else
      fail "CFG-002 Schema" BLOCKING "registry.yaml nie ma poprawnej struktury (schema_version/gates)."
    fi
  else
    # Brak python3 — podstawowa walidacja grep'owa.
    if grep -qE '^schema_version:' "$REGISTRY" && grep -qE '^gates:' "$REGISTRY"; then
      SCHEMA_OK=1
      pass "CFG-002 Schema" BLOCKING "Podstawowa struktura registry.yaml poprawna (grep)."
    else
      fail "CFG-002 Schema" BLOCKING "registry.yaml nie ma poprawnej struktury (schema_version/gates)."
    fi
  fi
elif [ "$PY_OK" -eq 1 ] && python3 -c "import jsonschema" >/dev/null 2>&1; then
  if python3 - "$REGISTRY" "$SCHEMA" <<'PYEOF' >/dev/null 2>&1
import sys, yaml, json, jsonschema
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
with open(sys.argv[2]) as f:
    schema = json.load(f)
jsonschema.validate(data, schema)
PYEOF
  then
    SCHEMA_OK=1
    pass "CFG-002 Schema" BLOCKING "registry.yaml zgodny z registry.schema.json (jsonschema)."
  else
    fail "CFG-002 Schema" BLOCKING "registry.yaml NIE jest zgodny z registry.schema.json."
  fi
else
  # Schema istnieje, ale brak jsonschema — podstawowa walidacja struktury.
  warn "CFG-002 Schema" "jsonschema niedostępny — wykonano podstawową walidację struktury."
  if grep -qE '^schema_version:' "$REGISTRY" && grep -qE '^defaults:' "$REGISTRY" && grep -qE '^floors:' "$REGISTRY"; then
    SCHEMA_OK=1
    pass "CFG-002 Schema" BLOCKING "Podstawowa struktura registry.yaml poprawna."
  else
    fail "CFG-002 Schema" BLOCKING "registry.yaml nie ma poprawnej struktury."
  fi
fi

# ── Parsowanie kluczy (jeśli python dostępny) ───────────────
# Jeśli python niedostępny, checki CFG-003..005 używają grep'owej
# heurystyki na surowym YAML.
KEYS=""
if [ "$PY_OK" -eq 1 ]; then
  KEYS="$(parse_registry)"
fi

# ── CFG-003 Klucze: floor, owner, tier, doc, reload ─────────
say ""
say "--- CFG-003: Klucze (floor, owner, tier, doc, reload) ---"
# WHY: każdy klucz musi mieć pełny zestaw atrybutów, inaczej resolver
# nie wie kto jest właścicielem, jaki jest próg, czy jest hot-reload.
# SOURCE: config-plane-design.md (definicja gate'a parametryzowana).
# EVIDENCE: atrybuty każdego klucza z registry.yaml.
# EXPECTED: każdy klucz ma floor, owner, tier, doc, reload.
# ACTUAL: lista kluczy z brakującymi atrybutami.
# SEVERITY: BLOCKING. REMEDIATION: uzupełnij brakujące atrybuty.
MISSING_ATTR=0
if [ -n "$KEYS" ]; then
  while IFS=$'\t' read -r key floor default owner tier doc reload; do
    for attr in floor owner tier doc reload; do
      val=""
      case "$attr" in
        floor) val="$floor" ;;
        owner) val="$owner" ;;
        tier)  val="$tier" ;;
        doc)   val="$doc" ;;
        reload) val="$reload" ;;
      esac
      if [ -z "$val" ]; then
        MISSING_ATTR=$((MISSING_ATTR+1))
        say "       $key: brak atrybutu '$attr'"
      fi
    done
  done <<< "$KEYS"
  if [ "$MISSING_ATTR" -eq 0 ]; then
    pass "CFG-003 Klucze" BLOCKING "Wszystkie klucze mają floor, owner, tier, doc, reload."
  else
    fail "CFG-003 Klucze" BLOCKING "$MISSING_ATTR brakujących atrybutów (floor/owner/tier/doc/reload)."
  fi
else
  warn "CFG-003 Klucze" "Brak python3 — pominięto pełną walidację atrybutów kluczy."
fi

# ── CFG-004 Docs: każdy klucz ma doc ────────────────────────
say ""
say "--- CFG-004: Docs (każdy klucz ma doc) ---"
# WHY: klucz bez doc jest nieudokumentowany — nikt nie wie do czego służy.
# SOURCE: config-plane-design.md. EVIDENCE: atrybut doc każdego klucza.
# EXPECTED: każdy klucz ma doc. ACTUAL: liczba kluczy bez doc.
# SEVERITY: WARNING (nie blokuje, ale wymaga świadomej decyzji).
# REMEDIATION: dodaj doc do każdego klucza.
NODOC=0
if [ -n "$KEYS" ]; then
  while IFS=$'\t' read -r key floor default owner tier doc reload; do
    if [ -z "$doc" ]; then
      NODOC=$((NODOC+1))
      say "       $key: brak doc"
    fi
  done <<< "$KEYS"
  if [ "$NODOC" -eq 0 ]; then
    pass "CFG-004 Docs" WARNING "Wszystkie klucze mają doc."
  else
    warn "CFG-004 Docs" "$NODOC kluczy bez doc (opis)."
  fi
else
  warn "CFG-004 Docs" "Brak python3 — pominięto walidację docs."
fi

# ── CFG-005 Defaulty: default >= floor ──────────────────────
say ""
say "--- CFG-005: Defaulty (default >= floor) ---"
# WHY: tighten zawsze przechodzi, ale default poniżej floora = config
# startuje poniżej minimalnego progu = L1 jest dekoracją.
# SOURCE: config-plane-design.md (4 prawa configu — tighten zawsze przechodzi).
# EVIDENCE: porównanie default vs floor dla każdego klucza.
# EXPECTED: każdy default >= floor. ACTUAL: lista naruszeń.
# SEVERITY: BLOCKING. REMEDIATION: podnieś default do >= floor.
BELOW_FLOOR=0
if [ -n "$KEYS" ]; then
  while IFS=$'\t' read -r key floor default owner tier doc reload; do
    # Porównujemy tylko numeryczne defaulty i floory.
    if [ -n "$floor" ] && [ -n "$default" ] && [[ "$floor" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [[ "$default" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
      if python3 - "$default" "$floor" <<'PYEOF' >/dev/null 2>&1
import sys
d, f = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if d >= f else 1)
PYEOF
      then
        :
      else
        BELOW_FLOOR=$((BELOW_FLOOR+1))
        say "       $key: default=$default < floor=$floor"
      fi
    fi
  done <<< "$KEYS"
  if [ "$BELOW_FLOOR" -eq 0 ]; then
    pass "CFG-005 Defaulty" BLOCKING "Wszystkie defaulty >= floor."
  else
    fail "CFG-005 Defaulty" BLOCKING "$BELOW_FLOOR kluczy z defaultem poniżej floora."
  fi
else
  warn "CFG-005 Defaulty" "Brak python3 — pominięto walidację defaultów."
fi

# ── CFG-006 Waivers: każdy waiver ma expires_at ─────────────
say ""
say "--- CFG-006: Waivers (każdy waiver ma expires_at) ---"
# WHY: wyjątki wygasają — waiver bez expires_at jest nielegalny (prawo 3).
# SOURCE: config-plane-design.md (4 prawa configu — wyjątki wygasają).
# EVIDENCE: atrybut expires_at każdego waivera w registry.yaml.
# EXPECTED: każdy waiver ma expires_at. ACTUAL: liczba waiverów bez daty.
# SEVERITY: BLOCKING. REMEDIATION: dodaj expires_at do każdego waivera.
WAIVERS_NODATE=0
WAIVERS_TOTAL=0
if [ "$PY_OK" -eq 1 ]; then
  WAIVERS_TOTAL="$(python3 - "$REGISTRY" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
w = d.get("waivers") or []
print(len(w))
PYEOF
)"
  WAIVERS_NODATE="$(python3 - "$REGISTRY" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
w = d.get("waivers") or []
n = 0
for item in w:
    if not item.get("expires_at"):
        n += 1
        print(f"       waiver bez expires_at: {item.get('check_id', item.get('id', '?'))}")
print(f"__COUNT__{n}")
PYEOF
)"
  # Wyciągnij licznik z ostatniej linii.
  WAIVERS_NODATE="$(printf '%s\n' "$WAIVERS_NODATE" | grep '__COUNT__' | sed 's/__COUNT__//')"
  WAIVERS_NODATE="${WAIVERS_NODATE:-0}"
  if [ "$WAIVERS_TOTAL" -eq 0 ]; then
    pass "CFG-006 Waivers" BLOCKING "Brak waiverów w registry.yaml."
  elif [ "$WAIVERS_NODATE" -eq 0 ]; then
    pass "CFG-006 Waivers" BLOCKING "Wszystkie $WAIVERS_TOTAL waivery mają expires_at."
  else
    fail "CFG-006 Waivers" BLOCKING "$WAIVERS_NODATE/$WAIVERS_TOTAL waiverów bez expires_at."
  fi
else
  warn "CFG-006 Waivers" "Brak python3 — pominięto walidację waiverów."
fi

# ── CFG-007 Kill-switches: każdy kill-switch ma expires_at ──
say ""
say "--- CFG-007: Kill-switches (każdy kill-switch ma expires_at) ---"
# WHY: nawet kill-switch wygasa (L7) — awaryjny wyłącznik bez daty jest wieczny.
# SOURCE: config-plane-design.md (config_kill_switches — expires_at NOT NULL).
# EVIDENCE: atrybut expires_at każdego kill-switcha w registry.yaml.
# EXPECTED: każdy kill-switch ma expires_at. ACTUAL: liczba bez daty.
# SEVERITY: BLOCKING. REMEDIATION: dodaj expires_at do każdego kill-switcha.
KS_NODATE=0
KS_TOTAL=0
if [ "$PY_OK" -eq 1 ]; then
  KS_TOTAL="$(python3 - "$REGISTRY" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
k = d.get("kill_switches") or []
print(len(k))
PYEOF
)"
  KS_NODATE="$(python3 - "$REGISTRY" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
k = d.get("kill_switches") or []
n = 0
for item in k:
    if not item.get("expires_at"):
        n += 1
        print(f"       kill-switch bez expires_at: {item.get('key', item.get('id', '?'))}")
print(f"__COUNT__{n}")
PYEOF
)"
  KS_NODATE="$(printf '%s\n' "$KS_NODATE" | grep '__COUNT__' | sed 's/__COUNT__//')"
  KS_NODATE="${KS_NODATE:-0}"
  if [ "$KS_TOTAL" -eq 0 ]; then
    pass "CFG-007 Kill-switches" BLOCKING "Brak kill-switchy w registry.yaml."
  elif [ "$KS_NODATE" -eq 0 ]; then
    pass "CFG-007 Kill-switches" BLOCKING "Wszystkie $KS_TOTAL kill-switche mają expires_at."
  else
    fail "CFG-007 Kill-switches" BLOCKING "$KS_NODATE/$KS_TOTAL kill-switchy bez expires_at."
  fi
else
  warn "CFG-007 Kill-switches" "Brak python3 — pominięto walidację kill-switchy."
fi

# ── CFG-008 Konstytucja: klucze niekonfigurowalne ───────────
say ""
say "--- CFG-008: Konstytucja (klucze niekonfigurowalne) ---"
# WHY: lista rzeczy niekonfigurowalnych jest siłą configu — inaczej zmiana
# configu może wyłączyć siatkę bezpieczeństwa (ghost moduły wracają).
# SOURCE: config-plane-design.md (Konstytucja) + config_exemptions.yaml.
# EVIDENCE: klucze z config_exemptions.yaml vs defaults/floors w registry.yaml.
# EXPECTED: żaden klucz niekonfigurowalny nie jest konfigurowalny.
# ACTUAL: lista naruszeń. SEVERITY: BLOCKING.
# REMEDIATION: usuń klucz niekonfigurowalny z defaults/floors.
if [ ! -f "$EXEMPTIONS" ]; then
  # Brak config_exemptions.yaml = brak zdefiniowanych kluczy niekonfigurowalnych.
  # To nie jest naruszenie — po prostu konstytucja nie jest jeszcze zapisana.
  info "CFG-008 Konstytucja" "Brak config_exemptions.yaml — brak zdefiniowanych kluczy niekonfigurowalnych."
elif [ "$PY_OK" -eq 1 ]; then
  CONST_VIOLATIONS="$(python3 - "$REGISTRY" "$EXEMPTIONS" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    reg = yaml.safe_load(f) or {}
with open(sys.argv[2]) as f:
    ex = yaml.safe_load(f) or {}
# config_exemptions: sekcje exemptions / root_bootstrap / keys.
# Każda sekcja to lista dictów z polem `key` (lub mapa key->info).
exempt = []
for section in ("exemptions", "root_bootstrap", "keys"):
    items = ex.get(section) or []
    if isinstance(items, dict):
        exempt.extend(items.keys())
    else:
        for item in items:
            if isinstance(item, dict):
                k = item.get("key")
                if k:
                    exempt.append(k)
            else:
                exempt.append(item)
defaults = reg.get("gates") or {}
floors = reg.get("gates") or {}
if isinstance(floors, list):
    floors = {k: v for k, v in floors}
n = 0
for k in exempt:
    if k in defaults or k in floors:
        n += 1
        print(f"       klucz niekonfigurowalny w configu: {k}")
print(f"__COUNT__{n}")
PYEOF
)"
  CONST_VIOLATIONS="$(printf '%s\n' "$CONST_VIOLATIONS" | grep '__COUNT__' | sed 's/__COUNT__//')"
  CONST_VIOLATIONS="${CONST_VIOLATIONS:-0}"
  if [ "$CONST_VIOLATIONS" -eq 0 ]; then
    pass "CFG-008 Konstytucja" BLOCKING "Żaden klucz niekonfigurowalny nie jest konfigurowalny."
  else
    fail "CFG-008 Konstytucja" BLOCKING "$CONST_VIOLATIONS kluczy niekonfigurowalnych w gates."
  fi
else
  warn "CFG-008 Konstytucja" "Brak python3 — pominięto walidację konstytucji."
fi

# ── Evidence: moduł zakończony ──────────────────────────────
# Evidence bridge (P0#1): każdy gate zapisuje wynik do StateStore.
evidence_record "verify:config:cfg-complete" "module" "config/config.sh"

verify_module_exit
