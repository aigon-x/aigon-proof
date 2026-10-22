#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/hypervisor-principal.sh — BRAMKA pakietu HYPERVISOR PRINCIPAL 1.0.0
#
#  Rozkaz Suwerena 2026-10-17: "wdroż kanonicznie jako capability i skille do
#  mesha i agentów, zarejestruj, dodaj do kanonu i ssot".
#
#  CO WERYFIKUJE (read-only, FAIL-closed):
#    H1  bundle obecny w SSOT: capability.json parsuje się, id/version zgodne,
#    H2  16 skilli: każdy katalog ma SKILL.md z frontmatter `name` == nazwa katalogu,
#    H3  registry/operations.json: 41 operacji, każda ma bramki pre/postflight
#        istniejące w registry/gates.json (zero sierot),
#    H4  registry/gates.json: 18 bramek, ID G01..G18 bez dziur,
#    H5  schemas/: 5 plików JSON Schema 2020-12, parsują się,
#    H6  capability zarejestrowana w config/canonical/capabilities.yaml z KOMPLETEM
#        pól (id/risk/owner/scope/audit/revocable/ttl_seconds) i 41 operacjami,
#    H7  forbidden: force_quorum / reboot_all / prune_all / raw_ssh_fallback /
#        copy_etc_pve / second_vm_author — wszystkie obecne (zakazy wpisane),
#    H8  integralność bundla: CHECKSUMS.sha256 przechodzi (dowód braku podmiany),
#    H9  checker offline: scripts/hv_contract.py validate-package kończy się 0
#        i NIE ogłasza actuator_authorization=true (kontrakt: to nie autoryzacja),
#    H10 kolektor PVE jest GET-only (żadnego POST/PUT/DELETE w kodzie),
#    H11 zero sekretów w bundlu (tskey_/BEGIN PRIVATE KEY/hasła token=),
#    H12 brak szablonowych TODO/placeholder w SKILL.md (pakiet ma być gotowy).
#
#  UŻYCIE:
#    bash tools/gates/hypervisor-principal.sh              # PASS/FAIL
#    BUNDLE_DIR=/tmp/kopia bash tools/gates/hypervisor-principal.sh
#    bash tools/gates/hypervisor-principal.sh --selftest   # dowód negatywny
#
#  EXIT: 0 = PASS, 1 = FAIL (każdy FAIL ma nazwany powód).
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE_DIR="${BUNDLE_DIR:-${ROOT}/skills/shared/hypervisor-principal}"
CAPS="${CAPS_FILE:-${ROOT}/config/canonical/capabilities.yaml}"
CAP_ID="hypervisor.principal.manage"
FAIL=0
note() { printf '  %-6s %s\n' "$1" "$2"; }
fail() { note FAIL "$1"; FAIL=1; }
ok()   { note OK   "$1"; }

# ── DOWÓD NEGATYWNY (--selftest) ───────────────────────────────────────────
# Bramka bez dowodu negatywnego NIE ISTNIEJE (kanon: sabotuj → FAIL, przywróć → PASS).
# Działa na KOPII bundla w mktemp; żywego drzewa nie dotyka.
if [ "${1:-}" = "--selftest" ]; then
  st_tmp="$(mktemp -d)"
  st_fail=0
  echo "== SELFTEST hypervisor-principal (kopia: ${st_tmp})"
  cp -a "${BUNDLE_DIR}" "${st_tmp}/bundle"

  run_gate() { BUNDLE_DIR="${st_tmp}/bundle" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; echo $?; }

  echo "  [S0] baseline (niesabotowany bundle)"; rc="$(run_gate)"
  [ "${rc}" -eq 0 ] && echo "       PASS rc=0 (zgodnie z oczekiwaniem)" || { echo "       FAIL rc=${rc} — baseline nie przechodzi"; st_fail=1; }

  echo "  [S1] sabotaż: TODO w SKILL.md"
  printf '\nTODO: uzupełnić\n' >> "$(find "${st_tmp}/bundle/skills" -name SKILL.md | head -1)"
  rc="$(run_gate)"
  [ "${rc}" -eq 1 ] && echo "       FAIL rc=1 (wykryte)" || { echo "       NIE WYKRYŁ (rc=${rc}) — bramka jest fikcją"; st_fail=1; }
  cp -a "${BUNDLE_DIR}/skills/." "${st_tmp}/bundle/skills/"

  echo "  [S2] sabotaż: bramka G18 usunięta z gates.json"
  python3 - "${st_tmp}/bundle/registry/gates.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["gates"]=[g for g in d["gates"] if g["id"]!="G18"]
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2)
PY
  rc="$(run_gate)"
  [ "${rc}" -eq 1 ] && echo "       FAIL rc=1 (wykryte)" || { echo "       NIE WYKRYŁ (rc=${rc})"; st_fail=1; }
  cp -a "${BUNDLE_DIR}/registry/gates.json" "${st_tmp}/bundle/registry/gates.json"

  echo "  [S3] sabotaż: fałszywy sekret w bundlu"
  printf 'tskey-auth-kFAKE1234567890\n' > "${st_tmp}/bundle/skills/H11-leak.txt"
  rc="$(run_gate)"
  [ "${rc}" -eq 1 ] && echo "       FAIL rc=1 (wykryte)" || { echo "       NIE WYKRYŁ (rc=${rc})"; st_fail=1; }
  rm -f "${st_tmp}/bundle/skills/H11-leak.txt"

  echo "  [S4] przywrócenie bundla"; rc="$(run_gate)"
  [ "${rc}" -eq 0 ] && echo "       PASS rc=0 (przywrócone)" || { echo "       FAIL rc=${rc} po przywróceniu"; st_fail=1; }

  rm -rf "${st_tmp}"
  if [ "${st_fail}" -ne 0 ]; then echo "SELFTEST: FAIL"; exit 1; fi
  echo "SELFTEST: PASS (4/4 — baseline, TODO, brak bramki i sekret wykryte, przywrócenie zielone)"
  exit 0
fi

# ── H8 najpierw: integralność (jeśli bundle podmieniony, dalsze testy nie mają sensu)
if [ -f "${BUNDLE_DIR}/CHECKSUMS.sha256" ]; then
  if ( cd "${BUNDLE_DIR}" && sha256sum -c CHECKSUMS.sha256 >/dev/null 2>&1 ); then
    ok "H8 integralność bundla (CHECKSUMS.sha256)"
  else
    fail "H8 integralność bundla — sha256sum -c NIE przeszło (bundle podmieniony/uszkodzony)"
  fi
else
  fail "H8 brak ${BUNDLE_DIR}/CHECKSUMS.sha256"
fi

# ── H1 capability.json
if [ -f "${BUNDLE_DIR}/capability.json" ]; then
  h1="$(python3 - "${BUNDLE_DIR}/capability.json" "${CAP_ID}" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    print("ERR parse: %s" % e); raise SystemExit(0)
cid, want = d.get("id"), sys.argv[2]
if cid != want: print("ERR id=%s != %s" % (cid, want))
elif not d.get("version"): print("ERR brak version")
else: print("OK %s v%s" % (cid, d.get("version")))
PY
)"
  case "${h1}" in OK*) ok "H1 capability.json: ${h1#OK }" ;; *) fail "H1 capability.json: ${h1#ERR }" ;; esac
else
  fail "H1 brak ${BUNDLE_DIR}/capability.json"
fi

# ── H2 16 skilli + frontmatter name == katalog
h2="$(python3 - "${BUNDLE_DIR}" <<'PY'
import os,re,sys
base=sys.argv[1]
skills_dir=os.path.join(base,"skills")
errs=[]; n=0
if not os.path.isdir(skills_dir):
    print("ERR brak katalogu skills/"); raise SystemExit(0)
for name in sorted(os.listdir(skills_dir)):
    p=os.path.join(skills_dir,name,"SKILL.md")
    if not os.path.isfile(p):
        errs.append("%s: brak SKILL.md" % name); continue
    txt=open(p,encoding="utf-8",errors="replace").read()
    if not txt.startswith("---"):
        errs.append("%s: brak frontmatter" % name); continue
    fm=txt.split("---",2)[1]
    m=re.search(r"^name:\s*(\S+)", fm, re.M)
    if not m: errs.append("%s: frontmatter bez name" % name); continue
    if m.group(1).strip('"\'') != name: errs.append("%s: name=%s" % (name,m.group(1)))
    if not re.search(r"^description:", fm, re.M): errs.append("%s: brak description" % name)
    n+=1
if n != 16: errs.append("skilli: %d (oczekiwane 16)" % n)
print("ERR " + "; ".join(errs[:4]) if errs else "OK 16 skilli")
PY
)"
case "${h2}" in OK*) ok "H2 skille: ${h2#OK }" ;; *) fail "H2 skille: ${h2#ERR }" ;; esac

# ── H3/H4 registry: operacje ↔ bramki (zero sierot) + ID bramek bez dziur
h34="$(python3 - "${BUNDLE_DIR}" <<'PY'
import json,os,sys
base=sys.argv[1]; errs=[]
try:
    ops=json.load(open(os.path.join(base,"registry/operations.json")))["operations"]
    gates=json.load(open(os.path.join(base,"registry/gates.json")))["gates"]
except Exception as e:
    print("ERR registry: %s" % e); raise SystemExit(0)
gids={g["id"] for g in gates}
if len(ops)!=41: errs.append("operacji %d != 41" % len(ops))
if len(gates)!=18: errs.append("bramek %d != 18" % len(gates))
for o in ops:
    pre=o.get("required_preflight_gates") or []
    post=o.get("required_postflight_gates") or []
    if not pre: errs.append("%s: brak preflight" % o["id"])
    for g in pre+post:
        if g not in gids: errs.append("%s: bramka %s nie istnieje" % (o["id"], g))
want={"G%02d" % i for i in range(1,19)}
if gids != want: errs.append("ID bramek != G01..G18 (brak: %s)" % ",".join(sorted(want-gids)))
print("ERR " + "; ".join(errs[:4]) if errs else "OK 41 operacji / 18 bramek, zero sierot")
PY
)"
case "${h34}" in OK*) ok "H3+H4 registry: ${h34#OK }" ;; *) fail "H3+H4 registry: ${h34#ERR }" ;; esac

# ── H5 schematy
h5="$(python3 - "${BUNDLE_DIR}" <<'PY'
import json,os,sys,glob
base=sys.argv[1]; files=sorted(glob.glob(os.path.join(base,"schemas","*.schema.json"))); errs=[]
if len(files)!=5: errs.append("schematow %d != 5" % len(files))
for f in files:
    try:
        d=json.load(open(f))
    except Exception as e:
        errs.append("%s: %s" % (os.path.basename(f), e)); continue
    if "2020-12" not in str(d.get("$schema","")): errs.append("%s: nie draft 2020-12" % os.path.basename(f))
print("ERR " + "; ".join(errs[:3]) if errs else "OK 5 schematow (2020-12)")
PY
)"
case "${h5}" in OK*) ok "H5 schematy: ${h5#OK }" ;; *) fail "H5 schematy: ${h5#ERR }" ;; esac

# ── H6 capability w rejestrze Access Controllera (komplet pól + 41 operacji)
h6="$(python3 - "${CAPS}" "${CAP_ID}" <<'PY'
import sys, yaml
path, cid = sys.argv[1], sys.argv[2]
try:
    doc=yaml.safe_load(open(path,encoding="utf-8"))
except Exception as e:
    print("ERR yaml: %s" % e); raise SystemExit(0)
caps=doc.get("capabilities") or []
me=[c for c in caps if c.get("id")==cid]
if not me: print("ERR brak wpisu %s (%d capability w rejestrze)" % (cid,len(caps))); raise SystemExit(0)
c=me[0]; missing=[k for k in ("risk","owner","scope","audit","revocable","ttl_seconds") if k not in c]
if missing: print("ERR brak pol: %s" % ",".join(missing)); raise SystemExit(0)
ops=c.get("operations") or []
if len(ops)!=41: print("ERR operacji we wpisie %d != 41" % len(ops)); raise SystemExit(0)
print("OK %s risk=%s ttl=%s ops=%d" % (cid, c.get("risk"), c.get("ttl_seconds"), len(ops)))
PY
)"
case "${h6}" in OK*) ok "H6 rejestr capability: ${h6#OK }" ;; *) fail "H6 rejestr capability: ${h6#ERR }" ;; esac

# ── H7 zakazy wpisane
h7="$(python3 - "${CAPS}" "${CAP_ID}" <<'PY'
import sys, yaml
doc=yaml.safe_load(open(sys.argv[1],encoding="utf-8"))
c=[x for x in (doc.get("capabilities") or []) if x.get("id")==sys.argv[2]]
need={"force_quorum","reboot_all_as_healing","prune_all","raw_ssh_fallback_on_permission_error","copy_etc_pve_as_cluster_management","second_vm_author"}
if not c: print("ERR brak capability"); raise SystemExit(0)
have=set(c[0].get("forbidden") or [])
miss=need-have
print("ERR brak zakazow: %s" % ",".join(sorted(miss)) if miss else "OK 6 zakazow")
PY
)"
case "${h7}" in OK*) ok "H7 zakazy: ${h7#OK }" ;; *) fail "H7 zakazy: ${h7#ERR }" ;; esac

# ── H9 checker offline (validate-package) — odporny na brak venv z jsonschema
PYBIN=""
for cand in "${ROOT}/tools/.venv-capability/bin/python" "${ROOT}/.venv-capability/bin/python"; do
  [ -x "${cand}" ] && { PYBIN="${cand}"; break; }
done
if [ -z "${PYBIN}" ]; then
  PYBIN="$(command -v python3 || true)"
fi
if [ -n "${PYBIN}" ] && [ -f "${BUNDLE_DIR}/scripts/hv_contract.py" ]; then
  out="$(cd "${BUNDLE_DIR}" && timeout 90 "${PYBIN}" scripts/hv_contract.py validate-package 2>&1)"; rc=$?
  if [ "${rc}" -ne 0 ]; then
    fail "H9 checker validate-package rc=${rc} (oczekiwane 0)"
  elif printf '%s' "${out}" | grep -qi '"actuator_authorization"[[:space:]]*:[[:space:]]*true'; then
    fail "H9 checker ogłasza actuator_authorization=true — łamie kontrakt (to nie autoryzacja)"
  else
    ok "H9 checker offline (validate-package rc=0, actuator_authorization != true)"
  fi
else
  fail "H9 brak interpretera (${PYBIN:-brak}) lub scripts/hv_contract.py — FAIL-closed"
fi

# ── H10 kolektor GET-only
if [ -f "${BUNDLE_DIR}/scripts/pve_readonly.py" ]; then
  if grep -qE 'method[[:space:]]*=[[:space:]]*["'"'"'](POST|PUT|DELETE|PATCH)' "${BUNDLE_DIR}/scripts/pve_readonly.py"; then
    fail "H10 kolektor PVE wykonuje metodę mutującą (POST/PUT/DELETE/PATCH) — ma być GET-only"
  else
    ok "H10 kolektor PVE GET-only"
  fi
else
  fail "H10 brak scripts/pve_readonly.py"
fi

# ── H11 zero sekretów w bundlu
leak="$(grep -rIlE 'tskey-(auth|api)-[A-Za-z0-9]|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|hvs\.[A-Za-z0-9]{10}' "${BUNDLE_DIR}" 2>/dev/null | head -3)"
if [ -n "${leak}" ]; then
  fail "H11 sekret w bundlu: $(printf '%s' "${leak}" | tr '\n' ' ')"
else
  ok "H11 zero sekretów w bundlu"
fi

# ── H12 brak szablonowych TODO w skillach
todo="$(grep -rIlE 'TODO|FIXME|XXX|<placeholder>|\[do uzupełnienia\]' "${BUNDLE_DIR}/skills" 2>/dev/null | head -3)"
if [ -n "${todo}" ]; then
  fail "H12 szablonowe TODO w skillach: $(printf '%s' "${todo}" | tr '\n' ' ')"
else
  ok "H12 skille bez TODO/placeholder"
fi

if [ "${FAIL}" -ne 0 ]; then
  echo "HYPERVISOR_PRINCIPAL: FAIL"
  exit 1
fi
echo "HYPERVISOR_PRINCIPAL: PASS (H1-H12: bundle+16 skilli+41 operacji+18 bramek+rejestr+zakazy+integralność+checker+GET-only+zero sekretów)"
exit 0
