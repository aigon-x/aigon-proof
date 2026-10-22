#!/usr/bin/env bash
# ui-delivery-truth.sh — BRAMKA: zmiana UI nie jest „oddana", jeśli nikt nie przeszedł ścieżki
# UŻYTKOWNIKA tak, jak zrobi to Suweren.
#
# ── SKĄD TA BRAMKA (rozka z Suwerena 2026-10-18/19) ────────────────────────────────────────────
# „nigdy nie oddajesz jak nie sprawdzisz tak jak to bedzie robi suweren".
# Zmierzone tego dnia: wdrożyłem „nowy układ" panelu i oddałem go z dowodem, że CSS zawiera
# właściwe klasy — a Suweren NIE MÓGŁ SIĘ ZALOGOWAĆ, bo przycisk „pokaż hasło" dostał styl CTA
# (akcent, 390×56 px) i przykrył pole hasła. Bramki, które to przepuściły, mierzyły PLIKI
# (`grep klasy w bundlu`), nie EFEKT (człowiek przy klawiaturze).
#
# ── CO SPRAWDZA ───────────────────────────────────────────────────────────────────────────────
# Istnienie i świeżość DOWODU PRZEJŚCIA ścieżki użytkownika dla KONKRETNEGO wydania konsoli:
#   evidence/ui-delivery/<produkt>/<release-hash>.json   (albo --evidence-dir)
# Wymagane pola:
#   release_hash       == wydanie wdrożone (alias nginx) — dowód dotyczy TEGO artefaktu
#   verified_at        <= 7 dni
#   checks.login       == "pass"          (logowanie faktycznie działa — formularz, nie plik)
#   pages[]            >= 3 odwiedzonych ekranów
#   screenshots[]      każdy plik istnieje i ma zgodny sha256 (dowód wizualny, nie opis)
#
# UŻYCIE:
#   bash tools/gates/ui-delivery-truth.sh                 # produkt phoneguard, wydanie z nginx
#   bash tools/gates/ui-delivery-truth.sh --product X --release <hash> --evidence-dir <dir>
#   bash tools/gates/ui-delivery-truth.sh --selftest      # dowód negatywny (sabotaż → FAIL)
set -uo pipefail
export LC_ALL=C

PRODUCT="phoneguard"
RELEASE=""
EVID_ROOT="/srv/aigon/evidence/ui-delivery"
SELFTEST=0
NGINX_CONF="/opt/projects/inorg/phoneguard/deploy/production/nginx.conf"
NGINX_HOST="${UI_GATE_HOST:-prod.mesh.internal}"

while [ $# -gt 0 ]; do
  case "$1" in
    --product) PRODUCT="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    --evidence-dir) EVID_ROOT="$2"; shift 2 ;;
    --nginx-conf) NGINX_CONF="$2"; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    *) echo "nieznana opcja: $1"; exit 2 ;;
  esac
done

say() { echo "  $*"; }

# Wydanie wdrożone = alias z konfiguracji nginx (źródło prawdy: co realnie serwuje panel).
deployed_release() {
  local rel=""
  if [ -n "${UI_GATE_CONF_LOCAL:-}" ] && [ -r "$UI_GATE_CONF_LOCAL" ]; then
    rel=$(grep -oE 'alias /projects/\.family-releases/console-[0-9a-f]{64}/' "$UI_GATE_CONF_LOCAL" | head -1 | grep -oE '[0-9a-f]{64}')
  else
    rel=$(ssh -o ConnectTimeout=8 -o BatchMode=yes -n "$NGINX_HOST" \
      "sudo -n grep -oE 'alias /projects/\.family-releases/console-[0-9a-f]{64}/' $NGINX_CONF 2>/dev/null | head -1" 2>/dev/null \
      | grep -oE '[0-9a-f]{64}')
  fi
  printf '%s' "$rel"
}

check_evidence() { # $1=release, $2=evidence dir → 0/1 + powody na stdout
  local release="$1" root="$2" file rc=0
  file="$root/$PRODUCT/$release.json"
  [ -f "$file" ] || file="$root/$release.json"
  if [ ! -f "$file" ]; then
    say "BRAK dowodu przejścia ścieżki użytkownika: $root/$PRODUCT/$release.json"
    say "  → nie oddawaj UI bez testu: login → klik przez ekrany → zrzuty → wpis dowodu"
    return 1
  fi
  python3 - "$file" "$release" <<'PY' || rc=1
import json,sys,os,hashlib,datetime
path,release=sys.argv[1],sys.argv[2]
try:
    d=json.load(open(path,encoding='utf-8'))
except Exception as e:
    print(f"  FAIL  dowod nie jest poprawnym JSON: {e}"); sys.exit(1)
bad=0
def norm(x):  # wydanie bywa zapisane jako "console-<hex>" albo samo <hex> — porownujemy RDZEN
    return str(x or "").replace("console-","").strip().lower()
if norm(d.get("release_hash"))!=norm(release):
    print(f"  FAIL  dowod dotyczy innego wydania ({norm(d.get('release_hash'))[:12]}… != {norm(release)[:12]}…)"); bad+=1
else:
    print(f"  PASS  dowod dotyczy wdrozonego wydania ({norm(release)[:12]}…)")
ts=d.get("verified_at","")
try:
    at=datetime.datetime.fromisoformat(ts.replace("Z","+00:00"))
    if at.tzinfo is None: at=at.replace(tzinfo=datetime.timezone.utc)
    age=(datetime.datetime.now(datetime.timezone.utc)-at).days
    if age<=7: print(f"  PASS  dowod swiezy ({age} dni)")
    else: print(f"  FAIL  dowod starszy niz 7 dni ({age})"); bad+=1
except Exception:
    print("  FAIL  brak/niepoprawne verified_at"); bad+=1
checks=d.get("checks") or {}
if checks.get("login")=="pass": print("  PASS  logowanie przeszlo (formularz, nie plik)")
else: print("  FAIL  brak dowodu logowania (checks.login != pass)"); bad+=1
pages=d.get("pages") or []
if len(pages)>=3: print(f"  PASS  ekrany odwiedzone: {len(pages)} (>=3)")
else: print(f"  FAIL  za malo ekranow: {len(pages)} (wymagane >=3)"); bad+=1
shots=d.get("screenshots") or []
if not shots:
    print("  FAIL  brak zrzutow ekranu"); bad+=1
for s in shots:
    p=s.get("path",""); want=s.get("sha256","")
    if not p or not os.path.isfile(p):
        print(f"  FAIL  zrzut nie istnieje: {p}"); bad+=1; continue
    got=hashlib.sha256(open(p,'rb').read()).hexdigest()
    if want and got!=want:
        print(f"  FAIL  zrzut zmieniony (sha rozny): {p}"); bad+=1
    else:
        print(f"  PASS  zrzut OK: {os.path.basename(p)}")
sys.exit(1 if bad else 0)
PY
  return $rc
}

if [ "$SELFTEST" = "1" ]; then
  echo "== SELFTEST (dowod negatywny: sabotaz MUSI wywolac FAIL) =="
  T=$(mktemp -d); mkdir -p "$T/ev/$PRODUCT"; FAKE=$(printf 'a%.0s' {1..64})
  SHOT="$T/shot.png"; printf 'x' > "$SHOT"; SHA=$(sha256sum "$SHOT" | awk '{print $1}')
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat > "$T/ev/$PRODUCT/$FAKE.json" <<JSON
{"release_hash":"$FAKE","verified_at":"$NOW","checks":{"login":"pass"},
 "pages":["login","devices","card"],"screenshots":[{"path":"$SHOT","sha256":"$SHA"}]}
JSON
  PRODUCT_SAVE="$PRODUCT"; PRODUCT="$PRODUCT"
  if PRODUCT="$PRODUCT" bash -c "UI_GATE_CONF_LOCAL=/dev/null" >/dev/null 2>&1; then :; fi
  # 1) komplet dowodow -> PASS
  if ( PRODUCT="$PRODUCT"; check_evidence "$FAKE" "$T/ev" ); then echo "  PASS  komplet dowodow -> PASS"; else echo "  FAIL  komplet dowodow nie przeszedl"; rm -rf "$T"; exit 1; fi
  # 2) sabotaz: login fail -> FAIL
  python3 - "$T/ev/$PRODUCT/$FAKE.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["checks"]["login"]="fail"; json.dump(d,open(p,'w'))
PY
  if ( PRODUCT="$PRODUCT"; check_evidence "$FAKE" "$T/ev" >/dev/null 2>&1 ); then echo "  FAIL  sabotaz logowania NIE zostal wykryty"; rm -rf "$T"; exit 1; else echo "  PASS  sabotaz logowania wykryty (FAIL)"; fi
  # 3) sabotaz: obcy release -> FAIL
  python3 - "$T/ev/$PRODUCT/$FAKE.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["checks"]["login"]="pass"; d["release_hash"]="b"*64; json.dump(d,open(p,'w'))
PY
  if ( PRODUCT="$PRODUCT"; check_evidence "$FAKE" "$T/ev" >/dev/null 2>&1 ); then echo "  FAIL  obcy release NIE zostal wykryty"; rm -rf "$T"; exit 1; else echo "  PASS  obcy release wykryty (FAIL)"; fi
  # 4) brak dowodu -> FAIL
  if ( PRODUCT="$PRODUCT"; check_evidence "c$FAKE" "$T/ev" >/dev/null 2>&1 ); then echo "  FAIL  brak dowodu NIE zostal wykryty"; rm -rf "$T"; exit 1; else echo "  PASS  brak dowodu wykryty (FAIL)"; fi
  rm -rf "$T"
  echo "SELFTEST: PASS"
  exit 0
fi

echo "== ui-delivery-truth: produkt=$PRODUCT =="
if [ -z "$RELEASE" ]; then
  RELEASE=$(deployed_release)
  if [ -z "$RELEASE" ]; then
    say "FAIL  nie ustalilem wdrozonego wydania konsoli (alias nginx na $NGINX_HOST)"
    say "      podaj --release <hash> albo sprawdz konfiguracje; BRAK POMIARU != PASS"
    echo "WERDYKT: FAIL"; exit 1
  fi
  say "wdrozone wydanie: ${RELEASE:0:12}…"
fi

if check_evidence "$RELEASE" "$EVID_ROOT"; then
  echo "WERDYKT: PASS (UI oddane z dowodem przejscia sciezki uzytkownika)"
  exit 0
else
  echo 'WERDYKT: FAIL (UI bez dowodu testu: tak, jak zrobi to Suweren)'
  exit 1
fi
