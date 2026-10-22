#!/usr/bin/env bash
# verify-egress-lockdown.sh — strażnik zakazu egressu modeli (LAW-EGRESS-1).
#
# Powstał po incydencie 2026-09-30: brama :38080 nie znała nazwy modelu
# i CICHO wysłała zadanie do https://router.aigon.dev:14008/v1 (płatny dostawca),
# aż konto zwróciło 402 Insufficient Balance. Agent spalił 10,6 mln tokenów
# i nie dowiózł pracy. Awaria bramy ma być GŁOŚNA i naprawiana z terminala,
# nigdy kupowana za pieniądze.
#
# ROZSZERZENIE 2026-09-30 (twardy rozkaz Suwerena: „agencie NIE MAJĄ PRAWA IŚĆ
# PRZEZ PŁATNE"). Bramka ma teraz SZEŚĆ niezależnych kontroli i FAIL-uje na
# KAŻDEJ z osobna:
#   A. KONFIG   — fallback modeli musi być pusty w konfigach agentów
#   B. LOG      — w logu bramy nie może być ani jednej eskalacji do chmury (okno 24h)
#   C. KOD      — ścieżka „nie znam modelu" musi kończyć się błędem, nie wysyłką
#   D. KASKADA  — każde ogniwo łańcucha agenta sklasyfikowane na 4 klasy kosztu;
#                 FAIL na PLATNY_ZA_TOKEN i na ogniwie bez dowodu odpowiedzi
#   E. KLUCZE   — klucz płatnego dostawcy widoczny w env/konfigu agenta = FAIL
#                 (strukturalne fail-closed: brak klucza = brak trasy)
#   F. NEGATYW  — dowód, że klasyfikator D NAPRAWDĘ łapie ogniwo płatne
#                 (przypadek negatywny; brak wykrycia = FAIL bramki)
#
# Uruchomienie:  bash /srv/aigon/tools/gates/verify-egress-lockdown.sh
# Exit: 0 = wszystko czyste, 1 = WYKRYTO WYCIEK (alarm).
set -uo pipefail

PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
info() { printf '  --    %s\n' "$*"; }

QHOME="${HOME_OPER:-/home/operator}"
PROXY="/srv/aigon/products/aigon-code/backend-rs/src/handlers/proxy.rs"
GATE_CONTAINER="${AIGON_GATE_CONTAINER:-aigon-code-server}"
WINDOW="${EGRESS_WINDOW:-24h}"
SSOT="/srv/aigon/config/agent-models.yaml"
CANON="/srv/aigon/config/canonical/agent-egress.yaml"

echo "=== GATE: egress lockdown (LAW-EGRESS-1) ==="

# ── A. KONFIG: fallback modeli w konfigach agentow ───────────────────────────
# KANON 2026-09-30: NIE wolno juz przepuscic dowolnego `:free` z chmury jako
# "bezpiecznego" — kaskada ma byc LOKALNY -> DARMOWY -> SUBSKRYPCJA. Kontrola A
# dalej wykrywa tylko ewidentnie PLATNE wpisy (bez `:free`); pelna klasyfikacja
# ogniw nalezy do kontroli D.
for f in "$QHOME/.qwen/settings.json" "$QHOME/.aigon/settings.json" "$QHOME/.claude/settings.json"; do
  [ -f "$f" ] || { info "brak $f — pomijam"; continue; }
  val="$(python3 -c "
import json,sys
try: d=json.load(open('$f',encoding='utf-8'))
except Exception: print('PARSE_ERROR'); raise SystemExit
def find(o):
    out=[]
    if isinstance(o,dict):
        for k,v in o.items():
            if k=='modelFallbacks': out.append(str(v))
            out+=find(v)
    elif isinstance(o,list):
        for v in o: out+=find(v)
    return out
r=find(d); print('|'.join(r) if r else 'ABSENT')
" 2>/dev/null)"
  case "$val" in
    ABSENT) ok "$(basename "$f"): brak modelFallbacks (bezpieczne)" ;;
    "''"|'""'|"[]"|"") ok "$(basename "$f"): modelFallbacks pusty" ;;
    PARSE_ERROR) bad "$(basename "$f"): nie da się sparsować (nie wiem, czy bezpieczny)" ;;
    *)
      platne="$(printf '%s' "$val" | tr '|' '\n' | grep -v '^$' | grep -cv ':free$' || true)"
      if [ "${platne:-1}" = "0" ]; then
        ok "$(basename "$f"): modelFallbacks bez wpisow spoza :free"
      else
        bad "$(basename "$f"): modelFallbacks ma ${platne} wpis(ów) SPOZA :free → $val"
      fi ;;
  esac
done

# ── B. LOG: ani jednej eskalacji do chmury w oknie ───────────────────────────
# UWAGA 2026-09-30: fix loguje przy odmowie linię
#   "… nieznany runtime → HTTP 400 (egress fallback ZAMKNIĘTY, LAW-EGRESS-1; …)"
# która ZAWIERA substring 'egress fallback', choć NIE jest eskalacją — to jej
# ZAMKNIĘCIE. Liczymy WYŁĄCZNIE realne eskalacje: linie z 'egress fallback' BEZ
# znacznika 'ZAMKNIĘTY'.
if command -v docker >/dev/null 2>&1 && docker inspect "$GATE_CONTAINER" >/dev/null 2>&1; then
  n="$(docker logs --since "$WINDOW" "$GATE_CONTAINER" 2>&1 | grep 'egress fallback' | grep -v 'ZAMKNIĘTY' | grep -c . || true)"
  if [ "${n:-0}" -eq 0 ]; then
    ok "log bramy ($WINDOW): 0 eskalacji do chmury"
  else
    bad "log bramy ($WINDOW): $n eskalacji do chmury (to są realne pieniądze)"
    docker logs --since "$WINDOW" "$GATE_CONTAINER" 2>&1 | grep 'egress fallback' | grep -v 'ZAMKNIĘTY' | tail -3 | sed 's/^/        /'
  fi
else
  info "kontener $GATE_CONTAINER niedostępny — kontrola logu pominięta"
fi

# ── C. KOD: nieznany model = błąd, nie wysyłka ───────────────────────────────
if [ -f "$PROXY" ]; then
  sites="$(grep -c 'unknown to runtime' "$PROXY" || true)"
  loud="$(grep -cE 'nieznany model|unknown_model|UNKNOWN_MODEL' "$PROXY" || true)"
  if [ "${loud:-0}" -ge 1 ]; then
    ok "kod: ścieżka fail-loud obecna ($loud wystąpień, miejsc 'unknown to runtime': $sites)"
  else
    bad "kod: BRAK fail-loud — 'unknown to runtime' nadal może eskalować ($sites miejsc)"
  fi
else
  info "brak $PROXY — kontrola kodu pominięta"
fi

# ── D. KASKADA: klasyfikacja ogniw na 4 klasy kosztu ─────────────────────────
# Czyta:
#   - modelFallbacks z ~/.qwen/settings.json (co harness NAPRAWDĘ uruchomi)
#   - agents.qwen.fallback_models z SSOT (zrodlo prawdy)
#   - modelProviders.openai (baseUrl + envKey kazdego modelu)
#   - config/canonical/agent-egress.yaml -> cascade[].dowod (dowod odpowiedzi)
# Klasyfikuje kazde ogniwo i FAIL-uje na PLATNY_ZA_TOKEN oraz na ogniwie bez
# dowodu odpowiedzi. Przypadek negatywny: patrz kontrola F.
CASCADE_JSON="$(python3 - "$QHOME/.qwen/settings.json" "$SSOT" "$CANON" <<'PY' 2>/dev/null
import json, sys, re
sett, ssot, canon = sys.argv[1], sys.argv[2], sys.argv[3]
PAID = {"DEEPSEEK_API_KEY","OPENAI_API_KEY","ANTHROPIC_API_KEY","XAI_API_KEY",
        "INCEPTION_API_KEY","NVIDIA_API_KEY"}
def classify(mid, prov):
    if prov is None:
        return "NIEROZWIAZALNE"
    base = (prov.get("baseUrl") or "").lower()
    env = (prov.get("envKey") or "")
    if mid.endswith(":free"):
        return "DARMOWY"
    if "127.0.0.1" in base or "localhost" in base:
        return "SUBSKRYPCJA" if ":38090" in base else "LOKALNY"
    if env in PAID:
        return "PLATNY_ZA_TOKEN"
    return "PLATNY_ZA_TOKEN"   # default-deny: nie-lokalny i nie-:free = platny
# prov mapy
prov_by_id = {}
try:
    d = json.load(open(sett))
    for p in (d.get("modelProviders", {}) or {}).get("openai", []) or []:
        prov_by_id.setdefault(str(p.get("id")), p)
    live = [x for x in str(d.get("modelFallbacks", "")).split(",") if x.strip()]
    live = [x.strip() for x in live]
except Exception:
    live = []
# SSOT fallback_models
ssot_links = []
try:
    txt = open(ssot).read()
    m = re.search(r"^    fallback_models:\n((?:      - .*\n)+)", txt, re.M)
    if m:
        ssot_links = [l.split("- ",1)[1].strip() for l in m.group(1).splitlines() if l.strip().startswith("- ")]
except Exception:
    ssot_links = []
# canon dowody
proof = {}
try:
    for line in open(canon):
        s = line.strip()
        mm = re.match(r'- link: "?([^"]+)"?$', s)
        if mm:
            cur = mm.group(1); proof.setdefault(cur, "")
        mm = re.match(r'dowod: "?(.*?)"?$', s)
        if mm and cur:
            proof[cur] = mm.group(1)
except Exception:
    pass
links = [("live", x) for x in live] + [("ssot", x) for x in ssot_links if x not in live]
out = []
for src, mid in links:
    cls = classify(mid, prov_by_id.get(mid))
    prf = proof.get(mid, "")
    has_proof = bool(prf) and "BRAK_POMIARU" not in prf
    out.append({"src": src, "link": mid, "klasa": cls,
                "dowod": ("ok" if has_proof else "BRAK")})
print(json.dumps(out))
PY
)"
if [ -z "$CASCADE_JSON" ]; then
  bad "kaskada: nie udało się odczytać łańcucha (BRAK_POMIARU)"
else
  echo "$CASCADE_JSON" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
if not rows: print('  --    kaskada: brak ogniw (pusta lista)')
seen=set()
for r in rows:
    key=(r['link'],r['klasa'],r['dowod'])
    if key in seen: continue
    seen.add(key)
    print('  --    ogniwo[{}] {} -> {} (dowód: {})'.format(r['src'], r['link'], r['klasa'], r['dowod']))
bad=0
for r in rows:
    if r['klasa']=='PLATNY_ZA_TOKEN':
        print('  FAIL  kaskada: ogniwo PLATNY_ZA_TOKEN w łańcuchu agenta -> {}'.format(r['link'])); bad+=1
    if r['dowod']!='ok':
        print('  FAIL  kaskada: ogniwo bez dowodu odpowiedzi -> {} (BRAK_POMIARU)'.format(r['link'])); bad+=1
import sys
sys.exit(1 if bad else 0)
" && ok "kaskada: żadne ogniwo nie jest PŁATNY_ZA_TOKEN i każde ma dowód" \
   || bad "kaskada: wykryto ogniwo PŁATNY_ZA_TOKEN lub bez dowodu (patrz wyżej)"
fi

# ── D2. TRASY W CAŁEJ LIŚCIE PROVIDERÓW — test TRASY, nie nazwy ──────────────
# Poprzednia wersja przepuszczała płatne trasy, gdy sync je PRZEMIANOWAŁ:
# etykieta „Paid: …" znikała, a `baseUrl: https://api.deepseek.com/v1` +
# `envKey: DEEPSEEK_API_KEY` ŻYŁY (zmierzone 2026-09-30: 300 tras, w tym 136×
# api.openai.com, 12× api.anthropic.com, 2× api.deepseek.com). Kryterium:
# żadna trasa agenta nie może celować w płatny endpoint ani używać klucza
# płatnego dostawcy. Loopback (:38080/:38090) nie jest płatny — to brama.
if [ -f "$QHOME/.qwen/settings.json" ]; then
  paid_routes="$(python3 - "$QHOME/.qwen/settings.json" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("PARSE_ERROR"); raise SystemExit
PAIDB = ("api.deepseek.com", "api.openai.com", "api.anthropic.com",
         "api.inceptionlabs.ai", "integrate.api.nvidia.com",
         "coding-intl.dashscope.aliyuncs.com")
PAIDE = {"DEEPSEEK_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
         "XAI_API_KEY", "INCEPTION_API_KEY", "NVIDIA_API_KEY"}
bad = []
for p in (d.get("modelProviders", {}) or {}).get("openai", []) or []:
    b = str(p.get("baseUrl") or "").lower()
    if "127.0.0.1" in b or "localhost" in b:
        continue
    if any(m in b for m in PAIDB) or str(p.get("envKey") or "") in PAIDE:
        bad.append(str(p.get("id")))
print(len(bad))
PY
)"
  case "$paid_routes" in
    PARSE_ERROR) bad "trasy: nie da się sparsować konfigu (nie wiem, czy czysty)" ;;
    ""|0) ok "trasy: 0 płatnych baseUrl/envKey w liście providerów agenta" ;;
    *) bad "trasy: $paid_routes wpisów z PŁATNYM baseUrl/envKey (api.deepseek/openai/anthropic/nvidia/inception)" ;;
  esac
fi

# ── E. KLUCZE PLATNYCH DOSTAWCOW — fail-closed (env + config + plaintext) ────
PAID_KEYS="DEEPSEEK_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY XAI_API_KEY INCEPTION_API_KEY NVIDIA_API_KEY"
# E1: klucze widoczne w BIEZACYM srodowisku agenta
leak_env=""
for k in $PAID_KEYS; do
  if [ -n "${!k:-}" ]; then leak_env="$leak_env $k"; fi
done
if [ -z "$leak_env" ]; then
  ok "env agenta: brak kluczy płatnych dostawców"
else
  bad "env agenta: WIDOCZNE klucze płatnych dostawców:$leak_env (restart sesji po fixie)"
fi
# E2: klucze placone obecne w zrodle env agenta (~/.qwen/.env) — daemon je laduje
if [ -f "$QHOME/.qwen/.env" ]; then
  leak_file=""
  for k in $PAID_KEYS; do
    if grep -qE "^[[:space:]]*${k}=" "$QHOME/.qwen/.env" 2>/dev/null; then leak_file="$leak_file $k"; fi
  done
  if [ -z "$leak_file" ]; then
    ok "~/.qwen/.env: brak kluczy płatnych dostawców"
  else
    bad "~/.qwen/.env: klucze płatnych dostawców wprost:$leak_file (drogą daemona omija wrapper)"
  fi
fi
# E3: sekret w PLAINTEKSCIE w wygenerowanym konfigu agenta
if [ -f "$QHOME/.qwen/settings.json" ]; then
  pt="$(python3 -c "
import json
PAID={'DEEPSEEK_API_KEY','OPENAI_API_KEY','ANTHROPIC_API_KEY','XAI_API_KEY','INCEPTION_API_KEY','NVIDIA_API_KEY'}
ALLOW={'AIGON_API_KEY','AIGON_RUNTIME_SHARED_SECRET','OLLAMA_API_KEY','OPENROUTER_API_KEY','BAILIAN_CODING_PLAN_API_KEY'}
out=[]
try: d=json.load(open('$QHOME/.qwen/settings.json'))
except Exception: print('PARSE_ERROR'); raise SystemExit
ak=((d.get('security') or {}).get('auth') or {}).get('apiKey')
if ak: out.append('security.auth.apiKey')
for k in (d.get('env') or {}):
    if k.endswith('_API_KEY') and k not in ALLOW: out.append('env.'+k)
print(','.join(out))
" 2>/dev/null)"
  case "$pt" in
    PARSE_ERROR) bad "settings.json: nie da się sparsować (nie wiem, czy czysty)" ;;
    "") ok "settings.json: brak sekretów w plaintekście" ;;
    *) bad "settings.json: sekret w PLAINTEKSCIE -> $pt" ;;
  esac
fi

# ── F. PRZYPADEK NEGATYWNY — klasyfikator D musi POZNAĆ ogniwo płatne ────────
# Wstrzykujemy sztuczne ogniwo z base_url PŁATNYM (api.deepseek.com) i sprawdzamy,
# że klasyfikator zwraca PLATNY_ZA_TOKEN. Brak wykrycia = bramka sama jest ślepa.
neg="$(python3 - <<'PY' 2>/dev/null
PAID={"DEEPSEEK_API_KEY","OPENAI_API_KEY","ANTHROPIC_API_KEY","XAI_API_KEY","INCEPTION_API_KEY","NVIDIA_API_KEY"}
def classify(mid, prov):
    if prov is None: return "NIEROZWIAZALNE"
    base=(prov.get("baseUrl") or "").lower(); env=prov.get("envKey") or ""
    if mid.endswith(":free"): return "DARMOWY"
    if "127.0.0.1" in base or "localhost" in base:
        return "SUBSKRYPCJA" if ":38090" in base else "LOKALNY"
    if env in PAID: return "PLATNY_ZA_TOKEN"
    return "PLATNY_ZA_TOKEN"
cases=[
 ("deepseek-v4-pro", {"baseUrl":"https://api.deepseek.com/v1","envKey":"DEEPSEEK_API_KEY"}, "PLATNY_ZA_TOKEN"),
 ("gpt-4o-mini",     {"baseUrl":"https://api.openai.com/v1","envKey":"OPENAI_API_KEY"}, "PLATNY_ZA_TOKEN"),
 ("claude-sonnet-4", {"baseUrl":"https://api.anthropic.com/v1","envKey":"ANTHROPIC_API_KEY"}, "PLATNY_ZA_TOKEN"),
 ("coding",          {"baseUrl":"http://localhost:38080/v1","envKey":"AIGON_API_KEY"}, "LOKALNY"),
 ("north-mini-code:free", {"baseUrl":"http://localhost:38080/v1","envKey":"AIGON_API_KEY"}, "DARMOWY"),
 ("sonnet",          {"baseUrl":"http://127.0.0.1:38090","envKey":""}, "SUBSKRYPCJA"),
 # PRZEMIANOWANE ogniwo płatne (wymóg parenta 2026-09-30): etykieta
 # „lokalny-model", ale TRASA do api.deepseek.com z kluczem DEEPSEEK_API_KEY.
 # Bramka testuje trasę, nie nazwę — MUSI to złapać.
 ("lokalny-model",   {"baseUrl":"https://api.deepseek.com/v1","envKey":"DEEPSEEK_API_KEY"}, "PLATNY_ZA_TOKEN"),
]
miss=[]
for mid,prov,want in cases:
    got=classify(mid,prov)
    if got!=want: miss.append("{}->{} (chcial {})".format(mid,got,want))
print("MISS" if miss else "OK" + (":"+";".join(miss) if miss else ""))
PY
)"
case "$neg" in
  OK) ok "przypadek negatywny: klasyfikator łapie ogniwa płatne i rozpoznaje lokalne/darmowe/subskrypcję" ;;
  *)  bad "przypadek negatywny: klasyfikator NIE łapie ogniwa płatnego ($neg) — bramka ślepa" ;;
esac

echo "==============================="
echo "WYNIK: $PASS PASS / $FAIL FAIL"
echo "==============================="
[ "$FAIL" -eq 0 ] || exit 1
