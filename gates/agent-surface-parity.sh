#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/agent-surface-parity.sh — GATE-121 AGENT-SURFACE-PARITY
# "wszyscy agenci mają TĘ SAMĄ powierzchnię — toczka w toczkę"
#
# DLACZEGO ISTNIEJE (zmierzone 2026-09-21):
#  * Wojna podjazdowa o „jedność agentów" była prowadzona NA DEKLARACJACH.
#    GATE-058 (agent-identity-parity) pilnuje już PROMPTU — pliki AGENTS.md
#    muszą być identyczne z renderem SSOT. Nikt nie pilnował reszty
#    powierzchni: serwerów MCP, narzędzi MCP, katalogów skilli.
#  * Zmierzone różnice, które NIE były niczyją decyzją:
#      - `magic-router` zadeklarowany w SSOT `mcp_servers`, a wpięty do ZERO
#        agentów (kanon 2026-09-06 wykluczył go świadomie jako duplikat :38080);
#      - `mcp__magic-router__*` w `agents.qwen.permissions.allow` — zgoda na
#        serwer, którego nie ma;
#      - narzędzia pamięci (`memory_search`/`memory_ingest`) miały w SSOT
#        deklarację tylko przy codexie; u pozostałych agentów „działały", bo
#        jadą z tym samym serwerem :38080 — ale nie było tego zapisane nigdzie,
#        więc każdy audyt musiał to odkrywać od zera;
#      - katalogi skilli: kanon identyczny dla wszystkich (rdzeń
#        context_budget z manifestu), a na dysku hermes miał +58 katalogów,
#        root-owe instancje qwen/hermes +27, qwen +4 pliki luzem.
#  * Dlatego bramka liczy EFEKTYWNĄ powierzchnię z REALNYCH plików agenta
#    (settings.json / config.yaml / config.toml / session.json) i porównuje
#    z kanonem SSOT. Nic nie jest brane z dokumentacji agenta.
#
# JAK PORÓWNUJE (bez drugiej implementacji kanonu):
#  * Całą logikę liczy `agent-surface-parity-check.py` obok — i to on importuje
#    scripts/sync-agent-models.py, żeby użyć TEJ SAMEJ definicji ścieżek
#    (`_ap_str("files", …)`) i TEGO SAMEGO rdzenia skilli (`_skills_core_set`),
#    które realnie zasilają agenta. Bramka nie ma własnej kopii ani ścieżek,
#    ani kanonu promptu — inaczej porównywałaby swoje wyobrażenie zamiast SSOT.
#  * Sonda `tools/list` na kanonicznej bramce :38080 jest DOWODEM, że narzędzia
#    z `surface.mcp_tools` naprawdę są wystawione. Brak sondy (offline) daje
#    WARN „nie potwierdzono", a NIE fałszywy PASS — brak podstawy nie jest
#    podstawą do zielonego.
#
# SEVERITY:
#  * BLOCKING — agent ma coś, czego kanon nie deklaruje (nadmiar serwera MCP,
#    nadmiar skilla z manifestu) albo nie ma czegoś, co kanon mu deklaruje
#    (brak serwera/narzędzia/skilla), albo SSOT deklaruje serwer bez
#    konsumenta. Wyjątki wyłącznie z `agents.<a>.surface_exceptions` (SSOT).
#  * WARNING  — katalog/plik POZA manifestem (sync tego z zasady nie rusza:
#    „katalog nieznany manifestowi (ręczny, cudzy, z innego źródła) NIE jest
#    ruszany”) oraz brak potwierdzenia live.
#
# Exit: 0 = PASS/WARN, 1 = FAIL, 2 = brak środowiska
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-121 AGENT-SURFACE-PARITY ==="

SSOT="${AIGON_SSOT:-$ROOT/config/agent-models.yaml}"
[ -r "$SSOT" ] || { say "brak $SSOT — pominieto"; exit 2; }

CHECKER="$(dirname "${BASH_SOURCE[0]}")/agent-surface-parity-check.py"
[ -f "$CHECKER" ] || { say "brak $CHECKER — pominieto (fail-closed: bramka zadeklarowana, a nieistniejaca)"; exit 2; }

OUT="$(python3 "$CHECKER" 2>&1)"
RC=$?
if [ "$RC" -eq 2 ]; then
  # Kontrakt modułu verify: 2 = brak środowiska. NIE udajemy PASS-a.
  say "nie moge policzyc powierzchni agentow:"
  say "$OUT"
  exit 2
fi

ILE=0; FAILE=0; WARNY=0; SUMMARY=""
while IFS=$'\t' read -r STATUS CHECK AGENT SEVERITY DETAIL; do
  [ -n "${STATUS:-}" ] || continue
  case "$STATUS" in
    SUMMARY)
      SUMMARY="$CHECK"  # pole 2 niesie payload (home=…/sondaz=…)
      continue ;;
    PASS) pass "$CHECK $AGENT" "${SEVERITY:-BLOCKING}" "$DETAIL"; ILE=$((ILE+1)) ;;
    FAIL) fail "$CHECK $AGENT" "${SEVERITY:-BLOCKING}" "$DETAIL"; FAILE=$((FAILE+1)) ;;
    WARN) warn "$CHECK $AGENT" "$DETAIL"; WARNY=$((WARNY+1)) ;;
    INFO) info "$CHECK $AGENT" "$DETAIL" ;;
    *)
      # Brak rozpoznanego statusu = nie wolno go zignorować (cichy zielony).
      fail "AGENT-SURFACE-PARITY-999 parser" BLOCKING "nierozpoznana linia raportu: $STATUS | $CHECK | $AGENT"
      FAILE=$((FAILE+1)) ;;
  esac
done <<< "$OUT"

if [ "$ILE" -eq 0 ] && [ "$FAILE" -eq 0 ]; then
  warn "AGENT-SURFACE-PARITY-000 brak podstawy" "checker nie zwrocil zadnego sprawdzenia (home bez konfiguracji agentow? ustaw AIGON_AGENT_HOME)"
fi

# Kontrakt dla wrappera hook-runnera: jedna linia maszynowa, żeby wrapper NIE
# musiał zgadywać, czy werdykt dotyczy realnego pomiaru, czy pustego home.
say "SURFACE-SUMMARY sprawdzen=$ILE fail=$FAILE warn=$WARNY ${SUMMARY:-home=nieznany}"

verify_module_exit
