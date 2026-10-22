#!/usr/bin/env bash
# LEX AEGIS GLOBAL — bramka weryfikująca instalację + kontrakt bramek G00-G10.
# Weryfikuje: skill zainstalowany, komplet 11 bramek (G00-G10), polityka
# fail-closed (zero autonomicznych send/sign/accept/settle/waive/...), oraz
# wpis capability w rejestrze. READ-ONLY — nie dotyka umów, nie wysyła.
set -uo pipefail
# ZMIERZONE 2026-10-19: bramka czytała skill z `$HOME/.hermes/skills/...`, więc
# wynik zależał od TEGO, KTO ją uruchomił: jako sniegul PASS, jako root (hook/
# reaktor) FAIL na wszystkich 8 blokadach i G00-G10 — fałszywy czerwony, który
# blokował constitution-fitness (LAW-LEX-AEGIS). SSOT skilli w tym repo to
# /opt/PROD/skills/shared (kanon dystrybucji), więc autorytetem jest TA kopia;
# instalacja per-user jest tylko fallbackiem.
SKILL="${LEX_AEGIS_SKILL:-/opt/PROD/skills/shared/lex-aegis-global}"
if [ ! -f "$SKILL/SKILL.md" ] && [ -f "$HOME/.hermes/skills/lex-aegis-global/SKILL.md" ]; then
  SKILL="$HOME/.hermes/skills/lex-aegis-global"
fi
FAIL=0

[ -f "$SKILL/SKILL.md" ]   || { echo "FAIL: brak SKILL.md (skill niezainstalowany)"; FAIL=1; }
[ -f "$SKILL/GATES.md" ]   || { echo "FAIL: brak GATES.md"; FAIL=1; }
[ -f "$SKILL/POLICY.yaml" ]|| { echo "FAIL: brak POLICY.yaml"; FAIL=1; }
[ -f "$SKILL/CAPABILITY.yaml" ] || { echo "FAIL: brak CAPABILITY.yaml"; FAIL=1; }

gates=$(grep -oE 'G(0[0-9]|10)' "$SKILL/GATES.md" 2>/dev/null | sort -u | wc -l)
if [ "${gates:-0}" -lt 11 ]; then echo "FAIL: bramki G00-G10 niekompletne ($gates/11)"; FAIL=1; fi

for a in send_external_message sign accept settle waive admit_debt make_payment delete_evidence; do
  grep -qE "^[[:space:]]*$a: false" "$SKILL/POLICY.yaml" 2>/dev/null \
    || { echo "FAIL: brak blokady fail-closed '$a'"; FAIL=1; }
done

grep -q "legal.contract_lifecycle.v1" /opt/PROD/config/canonical/capabilities.yaml 2>/dev/null \
  || { echo "FAIL: brak capability legal.contract_lifecycle.v1 w rejestrze"; FAIL=1; }

if [ "$FAIL" -ne 0 ]; then
  echo "LEX_AEGIS_GLOBAL: FAIL"
  exit 1
fi
echo "LEX_AEGIS_GLOBAL: PASS (skill + G00-G10 + fail-closed + capability)"
exit 0
