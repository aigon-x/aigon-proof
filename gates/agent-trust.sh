#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# gates/domains/agent-trust.sh — GATE-036 AGENT-TRUST
# "trust score w granicach"
#
# Trust agenta nie jest opinia — to sprawdzalne pytanie: czy agent jest
# skonfigurowany tak, jak deklaruje kanon? Agent, ktory omija bramke, nie ma
# evidence ani billingu; agent z oknem wiekszym niz serwer bedzie umieral
# w polowie zadania. Jedno i drugie obniza zaufanie do agenta i jego wynikow.
#
# DLACZEGO ISTNIEJE (zmierzone 2026-09-06):
#  * Hermes byl JEDYNYM agentem z glownym modelem w chmurze
#    (api.deepseek.com) — omijal :38080, router, billing, evidence i GPU,
#    wbrew regule "KAZDE polaczenie agenta idzie przez :38080".
#  * qwen/grok/hermes mialy podpiete DWA serwery MCP (aigon-code +
#    magic-router), ktore w duzej mierze sie dubluja — ~159 narzedzi.
#
# ROZSZERZENIE 2026-10-20 (P0 po spaleniu 60,33 USD/dobe na DeepSeek):
#  Bramka PRZEPUSZCZALA ten sam defekt, ktory miala lapac — bo sprawdzala
#  tylko "url nie zawiera 38080" i nie rozrozniala klasy kosztu toru.
#  Teraz:
#   * PLATNY ZA TOKEN jako tor DOMYSLNY agenta = FAIL (klasa: spalanie konta;
#     zmierzone 2026-10-20: 2700 wywolan prosto na api.deepseek.com obok
#     routera, budzet pokazywal 0.0 USD),
#   * DARMOWY tor chmurowy (nvidia/groq/github/openrouter/mistral/gemini/
#     cloudflare/pollinations/sambanova) = dopuszczony, ale WYMAGA uzasadnienia
#     `why` w SSOT (brama :38080/:14008 clampuje lokalny model do okna 32768,
#     a prompt Hermesa ma 32 792 tokeny — zmierzone 2026-10-20),
#   * tor nieznany = FAIL (fail-closed).
#
# Exit: 0 = PASS/WARN, 1 = FAIL, 2 = brak srodowiska
# ─────────────────────────────────────────────────────────────
set -u

# shellcheck source=../../core/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/lib.sh"

ROOT="$(verify_root)"
cd "$ROOT" || exit 1

SSOT="${AIGON_SSOT:-$ROOT/config/agent-models.yaml}"
MANIFEST="${AIGON_ROUTER_MANIFEST:-$ROOT/config/providers.yaml}"

# ── SELFTEST (dowody negatywne: płatny tor MUSI zgasić bramkę) ─────────────
if [ "${1:-}" = "--selftest" ]; then
  # TMPDIR bywa dziedziczony ze starej sesji i wskazywać na skasowany katalog —
  # wtedy mktemp pada i "selftest FAIL" kłamie o bramce. Fallback na /tmp.
  _t="$(mktemp -d 2>/dev/null || mktemp -d -p /tmp 2>/dev/null)"
  [ -n "${_t:-}" ] && [ -d "$_t" ] || { echo "SELFTEST ERROR: nie mogę utworzyć katalogu tymczasowego"; exit 2; }
  trap 'rm -rf "$_t"' EXIT
  printf 'agents:\n  test:\n    model:\n      default: x\n      base_url: "https://api.deepseek.com/v1"\n' > "$_t/paid.yaml"
  printf 'agents:\n  test:\n    model:\n      default: x\n      base_url: "https://integrate.api.nvidia.com/v1"\n    why: "darmowy tor, okno 131k"\n' > "$_t/free.yaml"
  printf 'agents:\n  test:\n    model:\n      default: x\n      base_url: "https://example.invalid/v1"\n' > "$_t/unknown.yaml"
  # Trasy: płatny PRZED lokalnym = defekt (klasa: grok/deepseek 2026-10-20).
  printf 'router_model_routes:\n  bad: ["github", "deepseek", "ollama-gpu", "runtime"]\n' > "$_t/route_bad.yaml"
  printf 'router_model_routes:\n  good: ["github", "ollama-gpu", "runtime", "deepseek"]\n' > "$_t/route_good.yaml"
  # Wybór JAWNY (płatny na pozycji 0) NIE jest defektem — musi przejść.
  printf 'router_model_routes:\n  deepseek-chat: ["deepseek", "openrouter", "ollama"]\n' > "$_t/route_explicit.yaml"
  AIGON_SSOT="$_t/free.yaml" AIGON_ROUTER_MANIFEST="$_t/route_good.yaml" bash "$0" >/dev/null 2>&1; _g=$?
  AIGON_SSOT="$_t/paid.yaml" AIGON_ROUTER_MANIFEST="$_t/route_good.yaml" bash "$0" >/dev/null 2>&1; _p=$?
  AIGON_SSOT="$_t/free.yaml" AIGON_ROUTER_MANIFEST="$_t/route_bad.yaml"  bash "$0" >/dev/null 2>&1; _r=$?
  AIGON_SSOT="$_t/free.yaml" AIGON_ROUTER_MANIFEST="$_t/route_explicit.yaml" bash "$0" >/dev/null 2>&1; _e=$?
  AIGON_SSOT="$_t/unknown.yaml" AIGON_ROUTER_MANIFEST="$_t/route_good.yaml" bash "$0" >/dev/null 2>&1; _u=$?
  if [ "$_g" -eq 0 ] && [ "$_p" -ne 0 ] && [ "$_r" -ne 0 ] && [ "$_e" -eq 0 ] && [ "$_u" -ne 0 ]; then
    echo "SELFTEST PASS (good=PASS paid=FAIL paidMidChain=FAIL explicitPaid=PASS unknown=FAIL)"
    exit 0
  fi
  echo "SELFTEST FAIL (good=$_g paid=$_p paidMid=$_r explicit=$_e unknown=$_u)"
  exit 1
fi

say "=== GATE-036 AGENT-TRUST ==="

[ -r "$SSOT" ] || { say "brak $SSOT — pominieto"; exit 3; }

RAPORT="$(python3 - "$SSOT" "$MANIFEST" <<'PY' 2>/dev/null
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
agenci = d.get("agents") or {}
naruszenia, ile = [], 0

# ── KLASY TORÓW (2026-10-20, po spaleniu 60 USD/dobę na DeepSeek) ──────────
# Bramka :38080 / router :14008 = tor kanoniczny (billing, evidence, gate).
GATE_HINTS = ("38080", "14008", "localhost", "127.0.0.1")
# DARMOWE tory chmurowe: koszt krancowy 0 — dopuszczone, gdy brama nie miesci
# promptu agenta (zmierzone: prompt Hermesa 32 792 tok. vs okno runtime 32768).
FREE_HOSTS = (
    "integrate.api.nvidia.com", "api.groq.com", "api.githubcopilot.com",
    "openrouter.ai", "api.mistral.ai", "generativelanguage.googleapis.com",
    "api.cloudflare.com", "text.pollinations.ai", "api.sambanova.ai",
)
# PLATNE ZA TOKEN: domyslny tor agenta = FAIL. To ta klasa spalila konto.
PAID_HOSTS = (
    "api.deepseek.com", "api.openai.com", "api.anthropic.com",
    "coding-intl.dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com",
    "api.inceptionlabs.ai", "api.x.ai", "api.moonshot.ai",
)

for nazwa, a in agenci.items():
    if not isinstance(a, dict):
        continue
    ile += 1
    m = a.get("model")
    url = (m.get("base_url", "") if isinstance(m, dict) else "") or ""
    # Trasa: pusty base_url = idzie przez `chain` (bramka) — to jest OK.
    if url and not any(x in url for x in GATE_HINTS):
        low = url.lower()
        if any(h in low for h in PAID_HOSTS):
            naruszenia.append(
                f"{nazwa}: DEFAULT NA PLATNYM TORZE {url} — poza bramka, "
                f"bez budzetu (klasa: spalanie konta 2026-10-20)")
        elif any(h in low for h in FREE_HOSTS):
            # darmowy tor: dopuszczony, ale musi byc UZASADNIONY w SSOT
            if not (m.get("why") or a.get("why")):
                naruszenia.append(
                    f"{nazwa}: darmowy tor {url} bez uzasadnienia `why` w SSOT")
        else:
            naruszenia.append(f"{nazwa}: base_url={url} — omija bramke :38080")
    mcp = a.get("mcp") or []
    # NAPRAWA 2026-10-01 (audyt bramek — klasa „detektor mierzy NIE tę rzecz"):
    # reguła liczy REALNĄ duplikację zestawów MCP, nie kardynalność listy.
    if len(set(mcp)) != len(mcp):
        naruszenia.append(f"{nazwa}: powtórzony wpis serwera MCP ({','.join(mcp)})")
    if "magic-router" in mcp and any("aigon-code" in x for x in mcp):
        naruszenia.append(f"{nazwa}: magic-router obok aigon-code — dublujące się zestawy narzędzi")

# ── TRASY ROUTERA (:14008): PŁATNY HOP NIE MOŻE STAĆ PRZED LOKALNYM ────────
# 2026-10-20: grok (models.default=`optimal`) szedł trasą, w której płatny
# deepseek stał PRZED ollama-gpu/runtime. Gdy darmowe tory wyczerpały limity
# (github/openrouter/nvidia 429 — zmierzone), ruch spadał na płatny hop,
# ZANIM spróbowano własnego GPU. Kanon kosztu: DARMOWE → GPU → kasa.
# Klasa płatna = DOKŁADNIE ta z routera (llm_routing::is_paid_provider) —
# jedno źródło klasy, żeby bramka nie spierała się z kodem.
LOCAL_HOPS = ("ollama", "ollama-gpu", "ollama-site", "ollama-prod", "ollama-cpu", "runtime")
PAID_HOPS = ("deepseek", "openai", "bailian", "inception")
try:
    man = yaml.safe_load(open(sys.argv[2])) or {}
    trasy = man.get("router_model_routes") or {}
    for nazwa_trasy, chain in trasy.items():
        if not isinstance(chain, list):
            continue
        low = [str(x).lower() for x in chain]
        i_paid = next((i for i, x in enumerate(low) if x in PAID_HOPS), None)
        i_loc = next((i for i, x in enumerate(low) if x in LOCAL_HOPS), None)
        # Wybór JAWNY (trasa nazwana modelem płatnym, np. `deepseek-chat`)
        # stawia płatny hop na pozycji 0 — to decyzja wołającego, nie kaskada.
        # Defektem jest płatny hop W ŚRODKU łańcucha, przed lokalnym GPU.
        if i_paid not in (None, 0) and i_loc is not None and i_paid < i_loc:
            naruszenia.append(
                f"trasa {nazwa_trasy}: PLATNY hop '{chain[i_paid]}' (poz. {i_paid}) "
                f"PRZED lokalnym '{chain[i_loc]}' (poz. {i_loc}) — platne przed GPU")
except FileNotFoundError:
    naruszenia.append(f"brak manifestu tras: {sys.argv[2]} (fail-closed)")

print(f"OK {ile} {len(naruszenia)}")
for n in naruszenia[:8]:
    print(f"  ! {n}")
PY
)"

case "$RAPORT" in
  ERR*|"")
    warn "AGENT-TRUST-001 zgodnosc konfiguracji agentow" ADVISORY "nie da sie odczytac SSOT"
    ;;
  *)
    ILE="$(echo "$RAPORT" | head -1 | awk '{print $2}')"
    N="$(echo "$RAPORT" | head -1 | awk '{print $3}')"
    echo "$RAPORT" | tail -n +2 | while IFS= read -r l; do [ -n "$l" ] && say "$l"; done
    if [ "${N:-0}" -eq 0 ]; then
      pass "AGENT-TRUST-001 zgodnosc konfiguracji agentow" BLOCKING \
        "$ILE agentow: zaden nie ma PLATNEGO toru domyslnego, brak duplikacji zestawow MCP"
    else
      fail "AGENT-TRUST-001 zgodnosc konfiguracji agentow" BLOCKING \
        "$N naruszen kanonu w konfiguracji $ILE agentow"
    fi
    ;;
esac

verify_module_exit
