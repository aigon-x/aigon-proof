#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/access-posture-check.sh — gate access-posture
#  (bezpieczeństwo dostępu administracyjnego — PRD §6, secure-access-controller)
#
#  READ-ONLY. Wykrywa luki z PRD §6 (stan as-is, ZMIERZONY nie z dokumentacji):
#    (a) publiczna reguła SSH dport 22 bez ograniczenia źródła — na KAŻDYM
#        węźle — DEFEKT P1 (P1 "Public SSH = ZERO": nigdy 0.0.0.0 -> TCP/22);
#    (b) PasswordAuthentication=yes w sshd;
#    (c) PermitRootLogin=yes w sshd;
#    (d) brak pliku ACL Tailscale w repo (config/canonical/tailscale-acl.hujson);
#    (e) brak rejestru capability (config/canonical/capabilities.yaml).
#
#  Część sieciową MIERZY istniejący tools/access-posture-audit.py --json
#  (wyjście parsowane jako JSON; klucz = nazwa węzła). Bramka WYPISUJE
#  KONKRETNE NAZWY naruszeń wraz z nazwą węzła (wymóg Suwerena:
#  "pokazywać które"), nie tylko licznik.
#
#  Kontrakt: exit 0 = PASS, exit 1 = FAIL (naruszenia §6 / P1), exit 2 = WARN.
#  Fail-closed: brak narzędzia pomiarowego = FAIL, nie PASS
#  (brak pomiaru != zero != sukces).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

AUDIT_SCRIPT="$ROOT/tools/access-posture-audit.py"
ACL_FILE="$ROOT/config/canonical/tailscale-acl.hujson"
CAP_FILE="$ROOT/config/canonical/capabilities.yaml"
# Limit fitness = 60s. Audyt sieci (8 węzłów równolegle, probe timeout 25s w
# samym audycie) trwa ~9s; 40s to zapas, a twardy sufit 45s gwarantuje, że
# bramka NIGDY nie przekroczy limitu (wcześniej 180s pozwalało przekroczyć 60s).
AUDIT_TIMEOUT="${AIGON_ACCESS_AUDIT_TIMEOUT:-40}"
(( AUDIT_TIMEOUT > 45 )) && AUDIT_TIMEOUT=45

cd "$ROOT" || { echo "access-posture-check: FAIL (nie mogę wejść do $ROOT)"; exit 1; }

declare -a FAILS=() WARNS=()
n_fail=0
n_warn=0
add_fail() { FAILS+=("$1"); n_fail=$((n_fail + 1)); }
add_warn() { WARNS+=("$1"); n_warn=$((n_warn + 1)); }

# ── (d) ACL Tailscale w repo ───────────────────────────────────────────────
if [ ! -f "$ACL_FILE" ]; then
  add_fail "[ACL] brak config/canonical/tailscale-acl.hujson — polityka Tailscale default-DENY (P2) NIE zrealizowana (w mocy reguła 'allow all within tailnet')"
fi

# ── (e) rejestr capability ─────────────────────────────────────────────────
if [ ! -f "$CAP_FILE" ]; then
  add_fail "[CAP] brak config/canonical/capabilities.yaml — brak capability plane (P3 'capability, nie port' / P6 'jeden plane autoryzacji')"
fi

# ── (a)(b)(c) pomiar sieci przez access-posture-audit.py --json ────────────
if [ ! -f "$AUDIT_SCRIPT" ]; then
  add_fail "[AUDIT] brak tools/access-posture-audit.py — brak pomiaru sieci (fail-closed)"
else
  AUDIT_JSON="$(timeout "$AUDIT_TIMEOUT" python3 "$AUDIT_SCRIPT" --json 2>/dev/null || true)"
  if [ -z "$AUDIT_JSON" ]; then
    add_fail "[AUDIT] access-posture-audit.py --json zwrócił PUSTO (fail-closed; brak pomiaru != PASS)"
  else
    RECORDS="$(printf '%s' "$AUDIT_JSON" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception as e:
    print("EDPARSE\t\t" + str(e)); sys.exit(0)
if not isinstance(data, dict):
    print("EDPARSE\t\troot JSON nie jest obiektem"); sys.exit(0)
def as_int(x):
    try: return int(x)
    except Exception: return 0
for node in sorted(data, key=str):
    v = data[node]
    if not isinstance(v, dict):
        print("%s\tEDPARSE\twartosc nie jest obiektem" % node); continue
    if v.get("error"):
        print("%s\tUNREACHABLE\t%s" % (node, v["error"])); continue
    pub = as_int(v.get("pub22"))
    if pub > 0:
        print("%s\tP1_PUB22\tpubliczna reguła 22 x%d (dport 22 bez ograniczenia źródła) — DEFEKT P1" % (node, pub))
    # policy accept = ruch niepasujący przechodzi → 22 z WAN otwarte (właściwy sygnał P1)
    pol = str(v.get("policy", "") or v.get("nftpolicy", "")).strip().lower()
    if pol == "accept":
        print("%s\tP1_POLICY\tINPUT policy=accept (ruch niepasujący przechodzi; 22 chronione tylko jawnym DROP) — WYMAGA policy drop" % node)
    if str(v.get("pass", "")).strip().lower() == "yes":
        print("%s\tPASSWD_YES\tPasswordAuthentication=yes" % node)
    root = str(v.get("root", "")).strip().lower()
    if root == "yes":
        print("%s\tROOT_YES\tPermitRootLogin=yes" % node)
    elif root == "without-password":
        print("%s\tROOT_WOPASSW\tPermitRootLogin=without-password" % node)
    if as_int(v.get("listen0")) > 0:
        print("%s\tLISTEN0\tListenAddress 0.0.0.0:22" % node)
')"
    while IFS=$'\t' read -r node kind detail; do
      [ -n "${node:-}" ] || continue
      case "${kind:-}" in
        P1_PUB22)     add_fail "[P1] $node: $detail" ;;
        P1_POLICY)    add_fail "[P1] $node: $detail" ;;
        PASSWD_YES)   add_fail "[SSH] $node: $detail" ;;
        ROOT_YES)     add_fail "[ROOT] $node: $detail" ;;
        ROOT_WOPASSW) add_warn "[WARN] $node: $detail" ;;
        LISTEN0)      add_warn "[WARN] $node: $detail" ;;
        UNREACHABLE)  add_warn "[WARN] $node: NIEOSIĄGALNY ($detail)" ;;
        EDPARSE)      add_fail "[AUDIT] błąd parsera JSON: $detail" ;;
        *)            add_warn "[WARN] $node: $kind $detail" ;;
      esac
    done <<< "$RECORDS"
  fi
fi

# ── Raport ─────────────────────────────────────────────────────────────────
echo "access-posture-check — bezpieczeństwo dostępu administracyjnego (PRD §6, READ-ONLY)"
if [ "$n_fail" -gt 0 ]; then
  for f in "${FAILS[@]}"; do echo "  $f"; done
fi
if [ "$n_warn" -gt 0 ]; then
  for w in "${WARNS[@]}"; do echo "  $w"; done
fi

if [ "$n_fail" -gt 0 ]; then
  echo "access-posture-check: FAIL — $n_fail naruszeń (P1/§6), $n_warn ostrzeżeń"
  exit 1
elif [ "$n_warn" -gt 0 ]; then
  echo "access-posture-check: WARN — 0 naruszeń P1/§6, $n_warn ostrzeżeń (do przeglądu)"
  exit 2
else
  echo "access-posture-check: PASS — 0 naruszeń, 0 ostrzeżeń"
  exit 0
fi
