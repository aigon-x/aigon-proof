#!/usr/bin/env bash
# ============================================================================
#  tools/gates/szpieg-sovereign-watch.sh — bramka kontraktu SZPIEG
# ============================================================================
#  PO CO (ROZKAZ SUWERENA 2026-10-13): pakiet SZPIEG_v1 to KONTRAKT nadzoru
#  interesu Suwerena (status lifecycle: SPECIFIED_UNBOUND — obserwator Rust
#  NIE zaimplementowany). Bramka egzekwuje, że kontrakt jest WPISANY do kanonu
#  (skill + capability + prawo) i że lifecycle pozostaje PRAWDZIWY (nikt nie
#  deklaruje ACTIVE_VERIFIED bez dowodu działania na runtime).
#
#  Kontrakt: 0 = PASS, 1 = FAIL. READ-ONLY (nie modyfikuje /opt/PROD; walidator
#  pakietu uruchamiany na kopii w mktemp, która jest usuwana). FAIL-CLOSED:
#  brak interpretera z zależnościami walidatora = FAIL (brak dowodu != PASS).
# ============================================================================
set -uo pipefail

ROOT="/opt/PROD"
# HOME_OPER — dom OPERATORA (SSOT), niezależny od tego, KTO woła bramkę (root/aigon).
# $HOME dawał FAŁSZYWA CZERWIEŃ, gdy reaktor (root, HOME=/root) szukał lokalnej
# instalacji skilla w /root/.hermes. Kanon: ten sam wzorzec co law-action-budget.sh /
# ledger-coverage.sh / leonardo-hpc-path.sh (toc 20eabee94216 — ujednolicenie HOME_OPER).
HOME_OPER="${AIGON_OPER_HOME:-/home/sniegul}"
LOCAL_SKILL="$HOME_OPER/.hermes/skills/szpieg-sovereign-watch"
SHARED_SKILL="$ROOT/skills/shared/szpieg-sovereign-watch"
FAIL=0
fail(){ echo "FAIL: $1"; FAIL=1; }
ok(){ echo "  OK  $1"; }

echo "== szpieg-sovereign-watch =="

# [1] Instalacja skilla: lokalny ($HOME) ORAZ SSOT shared (/opt/PROD)
for D in "$LOCAL_SKILL" "$SHARED_SKILL"; do
  [ -f "$D/SKILL.md" ]        || fail "brak SKILL.md w $D"
  [ -f "$D/capability.yaml" ] || fail "brak capability.yaml w $D"
  [ -d "$D/schemas" ]         || fail "brak schemas/ w $D"
  [ -d "$D/tools" ]           || fail "brak tools/ w $D"
  # reference/ (dokumentacja kontraktu). Akceptujemy też layout spłaszczony na
  # root (sync/ingest skilli normalizuje katalogi) — wtedy dowodem jest
  # SOVEREIGN_CONTRACT.yaml obok SKILL.md.
  if [ ! -d "$D/reference" ] && [ ! -f "$D/SOVEREIGN_CONTRACT.yaml" ]; then
    fail "brak dokumentacji kontraktu (reference/ lub SOVEREIGN_CONTRACT.yaml) w $D"
  fi
done
[ "$FAIL" -eq 0 ] && ok "skill zainstalowany (local + shared, z reference/schemas/tools)"

# [2] Lifecycle PRAWDZIWY: SPECIFIED_UNBOUND + bindingi null + kompletna deny-list
python3 - "$SHARED_SKILL/capability.yaml" <<'PY' || FAIL=1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
st = d.get('status', {})
assert st.get('lifecycle') == 'SPECIFIED_UNBOUND', "lifecycle != SPECIFIED_UNBOUND (upiększanie statusu bez dowodu runtime)"
assert st.get('runtime_verified') is False, "runtime_verified != false"
assert st.get('enabled') is False, "enabled != false"
b = d['spec']['bindings']
assert all(v is None for v in b.values()), "binding nie-null bez dowodu powiązania"
deny = set(d['spec']['authority']['deny'])
required = {'arbitrary_shell','runtime_data_mutation','deployment','service_restart',
            'rbac_changes','policy_changes','budget_increase','self_privilege_expansion',
            'arbitrary_recipient','secret_exfiltration','self_reinstatement_after_owner_stop'}
missing = required - deny
assert not missing, f"brak wpisów fail-closed w deny: {sorted(missing)}"
print("  OK  lifecycle=SPECIFIED_UNBOUND, bindingi null, deny-list kompletna")
PY

# [3] Wpis capability w rejestrze Access Controllera (config/canonical/capabilities.yaml)
grep -qE 'id:[[:space:]]*szpieg\.sovereign_watch' "$ROOT/config/canonical/capabilities.yaml" 2>/dev/null \
  || fail "brak capability szpieg.sovereign_watch w config/canonical/capabilities.yaml"
# operacje jako POD-WPISY (nie osobne capability) + komplet pól top-level
python3 - "$ROOT/config/canonical/capabilities.yaml" <<'PY' || FAIL=1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
caps = [c for c in d['capabilities'] if c.get('id') == 'szpieg.sovereign_watch']
assert len(caps) == 1, "capability szpieg.sovereign_watch nie występuje dokładnie raz"
c = caps[0]
for k in ('risk','owner','device','authn_method','ttl_seconds','max_sessions','scope','audit','revocable'):
    assert k in c, f"brak pola '{k}' w capability"
assert isinstance(c.get('operations'), list) and len(c['operations']) == 6, "operacje nie są pod-wpisami (6)"
print("  OK  capability + 6 operacji (pod-wpisy) w rejestrze")
PY

# [4] Prawo w fitness-map wskazuje TĘ bramkę
grep -q 'tools/gates/szpieg-sovereign-watch.sh' "$ROOT/config/canonical/constitution-fitness-map.yaml" 2>/dev/null \
  || fail "brak wpisu w constitution-fitness-map.yaml"

# [5] Defekt pakietu naprawiony: requirements.txt zawiera rfc3339-validator
grep -qE 'rfc3339-validator' "$SHARED_SKILL/tools/requirements.txt" 2>/dev/null \
  || fail "tools/requirements.txt bez rfc3339-validator (defekt: jsonschema FormatChecker bez date-time)"

# [6] Walidator pakietu 53/53 — na tymczasowej kopii (read-only dla /opt/PROD).
#     FAIL-CLOSED: brak interpretera z zależnościami = FAIL, nie skip.
PY_BIN=""
for c in "${SZPIEG_VALIDATOR_PY:-}" \
         "$ROOT/tools/.venv-capability/bin/python" \
         "$HOME_OPER/.hermes/skills/szpieg-sovereign-watch/.venv/bin/python" \
         python3; do
  [ -n "$c" ] || continue
  if [ -x "$c" ] || command -v "$c" >/dev/null 2>&1; then
    if "$c" -c 'import jsonschema,referencing,yaml,rfc3339_validator' >/dev/null 2>&1; then
      PY_BIN="$c"; break
    fi
  fi
done
if [ -z "$PY_BIN" ]; then
  fail "brak interpretera z deps walidatora (jsonschema/referencing/PyYAML/rfc3339-validator) — fail-closed; patrz tools/requirements.txt"
else
  TMP="$(mktemp -d)"
  cp -r "$SHARED_SKILL/." "$TMP/bundle/" 2>/dev/null || cp -r "$SHARED_SKILL" "$TMP/bundle"
  OUT="$("$PY_BIN" "$TMP/bundle/tools/validate_bundle.py" 2>&1)"
  echo "$OUT" | grep -q '"passed": true'    || fail "walidator pakietu != passed:true ($(echo "$OUT" | tr '\n' ' ' | head -c 200))"
  echo "$OUT" | grep -q '"passed_count": 53' || fail "walidator pakietu != 53/53"
  echo "$OUT" | grep -q '"deployment_performed": false' || fail "walidator deklaruje deployment (nie może)"
  rm -rf "$TMP"
  [ "$FAIL" -eq 0 ] && ok "walidator pakietu 53/53 (interpreter: $PY_BIN)"
fi

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "SZPIEG_SOVEREIGN_WATCH: FAIL"
  # ── ESKALACJA (ROZKAZ SUWERENA 2026-10-13) ────────────────────────────────
  # Naruszenie kontraktu SZPIEG = sprawa, o której Suweren ma się dowiedzieć.
  # Guard: NIE eskalujemy w hooku git (pre-commit odpala bramkę wielokrotnie —
  # dzwon przy każdym commicie = spam). Eskalacja idzie z cron/runnera lub gdy
  # jawnie AIGON_SZPIEG_ESCALATE=1. Dedup/budżet/quiet i tak chronią w eskalatorze.
  if [ -z "${GIT_DIR:-}" ] && [ "${AIGON_SZPIEG_ESCALATE:-0}" = "1" ]; then
    bash "$ROOT/scripts/aigon-szpieg-escalate.sh" \
      --severity CRITICAL \
      --subject "SZPIEG: naruszenie kontraktu Sovereign Watch" \
      --detail "Bramka szpieg-sovereign-watch FAIL (skill/capability/fitness/walidator). Sprawdz: $ROOT/tools/gates/szpieg-sovereign-watch.sh" \
      >>"${AIGON_SZPIEG_ESC_LOG:-/var/log/aigon/szpieg-escalate.log}" 2>&1 || true
  fi
  exit 1
fi
echo "SZPIEG_SOVEREIGN_WATCH: PASS (skill+capability+fitness+hooks-ready+walidator 53/53; lifecycle=SPECIFIED_UNBOUND)"
exit 0
