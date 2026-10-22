#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/agent-identity-parity.sh — GATE-123 AGENT-IDENTITY-PARITY
# KOREKTA ID 2026-09-21: ten skrypt rezerwowal GATE-058, ale GATE-058 w
# config/canonical/gate-registry.yaml to BASH-SYNTAX — kolizja identyfikatorow,
# przez ktora bramka biegla POZA rejestrem (GATE-INTEGRITY-003: sierota).
# Nadano wolny GATE-123 i zarejestrowano; nie wracac do GATE-058.
# "wszyscy agenci na TYM SAMYM kanonicznym promptcie"
#
# DLACZEGO ISTNIEJE (zmierzone 2026-09-21):
#  * Wspólny prompt agentów żyje w JEDNYM miejscu — `system_prompt.content`
#    w config/agent-models.yaml — i jest rozsyłany przez
#    scripts/sync-agent-models.py do plików tożsamości każdego agenta
#    (lista: config/agent-path.yaml → files.agent_rules; stan: 6 plików).
#  * Te pliki to KOPIE, nie symlinki. Nic nie pilnowało, że są identyczne:
#    wystarczyło, że jeden agent ma nieco inny AGENTS.md i obowiązują go inne
#    zasady niż resztę — bez żadnego sygnału, że tak się stało. Istniejący
#    test fabric (scripts/test_agent_fabric.py) porównuje wyłącznie ROZMIARY
#    (`len(set(sizes.values())) == 1`), więc zamiana znaku na znak przechodziła.
#  * ~/.qwen/QWEN.md również jest ładowany do kontekstu (loader qwen-code czyta
#    domyślnie ["QWEN.md","AGENTS.md"] i SKLEJA oba — nie ma nadpisywania).
#    Jeśli ktoś wklei tam drugą pełną kopię promptu, agent dostaje go DWA RAZY
#    albo dostaje wersję rozjechaną. QWEN.md ma zostać KRÓTKIM wskaźnikiem —
#    i ta bramka tego pilnuje.
#
# JAK PORÓWNUJE (bez drugiej implementacji renderu):
#  * SSOT renderuje `python3 scripts/sync-agent-models.py --render-identity`
#    → linie `<md5>\t<agent>\t<ścieżka>`. Bramka nie liczy renderu sama;
#    inaczej porównywałaby własne wyobrażenie o prompcie, a nie to, co sync
#    realnie zapisuje (klasyczny drift „gate vs SSOT").
#  * md5 jest tu ODCISKIEM PARYTETU, nie kontrolą bezpieczeństwa — jest tani
#    (6 sum) i właśnie dlatego bramka może stać w profilu `fast` (pre-commit).
#  * Agent z własnym addendum (`system_prompt.per_agent`, dziś tylko codex)
#    przechodzi: renderer uwzględnia addendum, więc porównujemy z renderem
#    DLA TEGO agenta. Rozjazd = plik różny od swojego renderu.
#
# Exit: 0 = PASS/WARN, 1 = FAIL (rozjazd tożsamości — blokuje), 2 = brak środowiska
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

say "=== GATE-123 AGENT-IDENTITY-PARITY ==="

SSOT="${AIGON_SSOT:-$ROOT/config/agent-models.yaml}"
[ -r "$SSOT" ] || { say "brak $SSOT — pominieto"; exit 2; }
SYNC="$ROOT/scripts/sync-agent-models.py"
[ -f "$SYNC" ] || { say "brak $SYNC — pominieto"; exit 2; }

# ── Home, w którym leżą pliki tożsamości ─────────────────────
# Kanon to pliki w home operatora. Sync odpalany jest także z crona jako root,
# więc `~` procesu NIE jest tym samym `~` co `~` celu. Bramka wskazuje home
# jawnie: AIGON_AGENT_HOME → /home/operator (jeśli czytelny) → $HOME.
CANON_HOME="${AIGON_AGENT_HOME:-}"
if [ -z "$CANON_HOME" ]; then
  if [ -r /home/operator/.qwen ]; then
    CANON_HOME=/home/operator
  else
    CANON_HOME="$HOME"
  fi
fi

RENDER="$(python3 "$SYNC" --render-identity 2>&1)"
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$RENDER" ]; then
  # Kontrakt modułu verify: 2 = brak środowiska (jak agent-trust.sh).
  # NIE udajemy PASS-a — brak renderu to brak podstawy do jakiegokolwiek werdyktu.
  say "nie moge wyrenderowac wspolnego promptu z SSOT (rc=$RC):"
  say "$RENDER"
  exit 2
fi

# ── Kontrola 1: każdy plik tożsamości == render z SSOT ───────
# FAIL BLOCKING: plik istnieje, ale różni się od kanonu → agent działa na
# INNYCH zasadach niż reszta (dokładnie ten drift, dla którego jest ta bramka).
# WARN: pliku nie ma → agent nie jest zainstalowany (nie każdy musi być).
ILE=0; BRAK=0; ROZJAZD=0; HASHE_DYSK=""
while IFS=$'\t' read -r EXPECT AGENT PATH_IN; do
  [ -n "${EXPECT:-}" ] || continue
  # Rebase ścieżki z home procesu na home kanonu (sync rozsyła na oba).
  case "$PATH_IN" in
    "$HOME"/*) TARGET="$CANON_HOME${PATH_IN#"$HOME"}" ;;
    *)         TARGET="$PATH_IN" ;;
  esac
  ILE=$((ILE+1))
  if [ ! -f "$TARGET" ]; then
    warn "AGENT-IDENTITY-PARITY-001 $AGENT" \
      "brak pliku tozsamosci ($TARGET) — agent nie zainstalowany"
    BRAK=$((BRAK+1))
    continue
  fi
  ACTUAL="$(md5sum "$TARGET" | awk '{print $1}')"
  HASHE_DYSK="$HASHE_DYSK$ACTUAL
"
  if [ "$ACTUAL" = "$EXPECT" ]; then
    pass "AGENT-IDENTITY-PARITY-001 $AGENT" BLOCKING "identyczny z SSOT ($ACTUAL)"
  else
    fail "AGENT-IDENTITY-PARITY-001 $AGENT" BLOCKING \
      "ROZJAZD tozsamosci: $TARGET ma $ACTUAL, SSOT renderuje $EXPECT — napraw: python3 scripts/sync-agent-models.py"
    ROZJAZD=$((ROZJAZD+1))
  fi
done <<< "$RENDER"

# ── Kontrola 2: grupy hashy — dysk kontra SSOT ───────────────
# To NIE jest „wszystkie pliki identyczne" (codex ma per_agent i CELOWO jest
# inny). Sprawdzamy, czy liczba RÓŻNYCH hashy na dysku nie przekracza liczby
# grup, które renderuje SSOT — czyli czy nikt nie dopisał sobie własnej wersji
# promptu obok wersji kanonicznej.
if [ "$ILE" -eq "$BRAK" ]; then
  warn "AGENT-IDENTITY-PARITY-002 wspolny rdzen" \
    "zadnego z $ILE plikow tozsamosci nie ma w $CANON_HOME — parytetu NIE sprawdzono (ustaw AIGON_AGENT_HOME albo uruchom jako wlasciciel home)"
else
  ROZNE="$(printf '%s\n' "$HASHE_DYSK" | awk 'NF' | sort -u | grep -c . || true)"
  OCZEK="$(printf '%s\n' "$RENDER" | awk -F'\t' 'NF{print $1}' | sort -u | grep -c . || true)"
  if [ "${ROZNE:-0}" -le "${OCZEK:-0}" ]; then
    pass "AGENT-IDENTITY-PARITY-002 wspolny rdzen" BLOCKING \
      "grupy hashy na dysku=$ROZNE, grupy z SSOT=$OCZEK (zgodnie; sprawdzono $((ILE-BRAK))/$ILE plikow)"
  else
    fail "AGENT-IDENTITY-PARITY-002 wspolny rdzen" BLOCKING \
      "grup hashy na dysku=$ROZNE > grup z SSOT=$OCZEK — ktos dopisal wlasna wersje promptu obok kanonicznej"
  fi
fi

# ── Kontrola 3: sierota ~/.qwen/QWEN.md zostaje WSKAZNIKIEM ──
# QWEN.md i AGENTS.md laduja sie OBA (domyslne nazwy kontekstu qwen-code),
# wiec QWEN.md ma wskazywac kanon, a nie go duplikowac. Pelna kopia w QWEN.md
# = prompt w kontekscie dwa razy (i drugie zrodlo prawdy w tym samym katalogu).
QWEN_MD="$CANON_HOME/.qwen/QWEN.md"
if [ -f "$QWEN_MD" ]; then
  QSIZE="$(stat -c %s "$QWEN_MD" 2>/dev/null || echo 0)"
  if [ "$QSIZE" -le 4096 ] && grep -q 'AIGON-IDENTITY-POINTER' "$QWEN_MD" \
     && grep -q 'AGENTS\.md' "$QWEN_MD"; then
    pass "AGENT-IDENTITY-PARITY-003 QWEN.md wskaznik" WARNING \
      "$QWEN_MD to wskaznik ($QSIZE B) do AGENTS.md — bez duplikatu promptu"
  else
    fail "AGENT-IDENTITY-PARITY-003 QWEN.md wskaznik" WARNING \
      "$QWEN_MD ($QSIZE B) NIE jest krotkim wskaznikiem do AGENTS.md — sierota rozjechana z SSOT (duplikat promptu w kontekscie); wzorzec: znacznik 'AIGON-IDENTITY-POINTER' + wskazanie AGENTS.md, max 4096 B"
  fi
else
  info "AGENT-IDENTITY-PARITY-003 QWEN.md wskaznik" "brak $QWEN_MD — pominieto"
fi

if [ "$ROZJAZD" -gt 0 ]; then
  say "rozjazd: $ROZJAZD z $ILE plikow tozsamosci (brak pliku: $BRAK, home: $CANON_HOME)"
fi

# Kontrakt dla wrappera hook-runnera (tools/gates/agent-identity-parity.sh):
# jedna linia maszynowa, żeby wrapper NIE musiał zgadywać, czy „brak plików"
# to PASS, czy nie-sprawdzone. Wrapper bez tego raportował PASS 0/6 —
# czyli dokładnie ten fałszywy zielony, przed którym ta bramka ma chronić.
say "PARITY-SUMMARY sprawdzono=$((ILE-BRAK))/$ILE rozjazd=$ROZJAZD brak=$BRAK home=$CANON_HOME"

verify_module_exit
