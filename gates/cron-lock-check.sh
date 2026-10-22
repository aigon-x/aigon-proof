#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  tools/gates/cron-lock-check.sh — BRAMKA: cron bez locka = kumulacja
#
#  LAW-Cron-1 (2026-09-30): Każde zadanie cykliczne MUSI mieć zabezpieczenie
#  przed nakładaniem się przebiegów (flock) ALBO być świadomie idempotentne
#  i równoległe (jawny waiver). Brak locka = nie wolno wpiąć do crona.
#
#  DLACZEGO BRAMKA, A NIE KOLEJNY WPIS W PAMIĘCI
#   Zmierzone 2026-09-30: 78 z ~90 skryptów cron nie miało flocka, a 27
#   kumulowało się w chwili pomiaru (docker-protect ×7, aigon-oob-voice ×5,
#   mesh-runtime-watchdog ×5). Na prod-aigon: 316 równoległych
#   backup-freshness.sh (najstarsza 13 h) i 81 jednoczesnych `find /mnt/nas`
#   z PPID=1. Skutek: load 98-108 na 14 rdzeniach → peer_eligible()
#   (scatter_gather.rs:837) wymaga load <= AIGON_SCATTER_LOAD_MAX (0.85) →
#   żaden peer się nie kwalifikuje → mesh_free_slots()=0 → scatter spada na
#   local → 1 subtask, spread_ok=0. Suweren nazwał to „nie mamy równoległości".
#   Wpis w pamięci NIE chroni przed tym — chroni tylko bramka.
#
#  SPRAWDZA
#   1. Każdy wpis /etc/cron.d/aigon-cron wołający .sh/.py MA flock ALBO
#      cron-run.sh ALBO jawny waiver.
#   2. Żaden skrypt NIE kumuluje się TERAZ (pgrep -fc > 1 przy braku locka).
#   3. Wpisy w cronie wskazują ISTNIEJĄCE pliki (fałszywy cel = cicha awaria).
#
#  WYJŚCIE: exit 0 = PASS/WARN, exit 1 = FAIL (kontrakt hook-runner.sh)
#
#  WAIVER: config/canonical/cron-lock-waivers.yaml
#    waivers:
#      - script: nazwa.sh
#        reason: "idempotentny, sam serializuje przez flock wewnątrz"
#        owner: Suweren
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
export LC_ALL=C

ROOT="${AIGON_PROJECT_ROOT:-/opt/PROD}"
CRON="${AIGON_CRON_FILE:-/etc/cron.d/aigon-cron}"
WAIVERS="${ROOT}/config/canonical/cron-lock-waivers.yaml"
[ -r "$CRON" ] || { echo "FAIL cron-lock-check: brak $CRON"; exit 1; }

FAILS=0
WARNS=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*"; FAILS=$((FAILS+1)); }
warn() { echo "  WARN $*"; WARNS=$((WARNS+1)); }

# ── waiver set ────────────────────────────────────────────────────────────
declare -A WAIVED=()
if [ -r "$WAIVERS" ]; then
  while IFS= read -r s; do
    [ -n "$s" ] && WAIVED["$s"]=1
  done < <(python3 - "$WAIVERS" <<'PY' 2>/dev/null
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
    for w in (d.get("waivers") or []):
        if isinstance(w, dict) and w.get("script"):
            print(str(w["script"]).strip())
except Exception:
    pass
PY
)
fi

echo "== cron-lock-check (LAW-Cron-1) =="
echo "   cron: $CRON"

# ── 0. OKABLOWANIE (KONKURS-GAP#3) — SSOT→cron, semafory, obserwator ───────
#  Bez tej sekcji „zadeklarowane ale nieodpalane" i cicha POMINIETO nie mają
#  bramki: cron wygląda na wpięty, a zadanie nie wstaje. Trzy niezależne osie:
#  (a) DRIFT SSOT↔/etc/cron.d, (b) uprawnienia semafora (cicha POMINIETO),
#  (c) obserwator celów (CronDeclaredNoCron / CronTargetMissing) świeży i 0.
echo "  --- okablowanie SSOT->cron + semafory + obserwator ---"

# (a) DRIFT: cron.yaml → sync-cron.py → /etc/cron.d/aigon-cron
if [ -r "$ROOT/scripts/sync-cron.py" ]; then
  if _out="$(python3 "$ROOT/scripts/sync-cron.py" --check 2>&1)"; then
    ok "SSOT->cron: ${_out##*sync-cron: }"
  else
    bad "SSOT->cron DRIFT: ${_out##*sync-cron: } (napraw: sudo python3 $ROOT/scripts/sync-cron.py)"
  fi
else
  warn "brak $ROOT/scripts/sync-cron.py — nie moge zmierzyc dryfu SSOT->cron"
fi

# (b) UPRAWNIENIA SEMAFORA — bez grupy aigon `exec 8>lock` pada → _acquired=0
#     → cron-run.sh konczy „POMINIETO ... exit 0" (cicha awaria, brak sladu).
if [ "$(id -u)" -eq 0 ]; then
  for _p in /run/aigon-cron-semaphore.lock /run/aigon-cron-access-semaphore.lock /run/aigon-cron-probe-semaphore.lock; do
    if [ ! -e "$_p" ]; then bad "brak semafora $_p (cron-run.sh pominie zadania usera sniegul)"; continue; fi
    _g="$(stat -c '%G' "$_p")"
    case "$(stat -c '%A' "$_p")" in ?rw*) : ;; *) bad "semafor $_p bez zapisu grupy ($(stat -c '%A' "$_p"), grupa $_g)"; ;; esac
    [ "$_g" = "aigon" ] || bad "semafor $_p grupa $_g != aigon"
  done
  if id sniegul >/dev/null 2>&1; then
    if sudo -u sniegul bash -c 'exec 8>/run/aigon-cron-semaphore.lock' 2>/dev/null; then
      ok "semafor otwierany przez sniegul (cicha POMINIETO zamknieta)"
    else
      bad "sniegul NIE otwiera /run/aigon-cron-semaphore.lock — cron-run.sh pominie jego zadania po cichu"
    fi
  fi
else
  warn "bramka bez root — pomijam pomiar uprawnien semafora (uruchom jako root, jak w hook-runner)"
fi

# (c) OBSERWATOR celow — metryka textfile musi byc swieza i zerowa.
_TPROM="/var/lib/node_exporter/textfile_collector/aigon-cron-targets.prom"
if [ -r "$_TPROM" ]; then
  _dnc="$(grep -oE 'aigon_cron_declared_no_cron\{[^}]*\} [0-9.]+' "$_TPROM" | awk '{print $NF}' | head -1)"
  _tmi="$(grep -oE 'aigon_cron_target_missing\{[^}]*\} [0-9.]+' "$_TPROM" | awk '{print $NF}' | head -1)"
  _tot="$(grep -oE 'aigon_cron_targets_total [0-9.]+' "$_TPROM" | awk '{print $NF}' | head -1)"
  _lru="$(grep -oE 'aigon_cron_target_check_last_run [0-9.]+' "$_TPROM" | awk '{print $NF}' | head -1)"
  _now="$(date +%s)"
  if [ "${_dnc:-0}" = "0" ]; then ok "CronDeclaredNoCron = 0 (sprawdzono ${_tot:-?} wpisow)"; else bad "CronDeclaredNoCron = ${_dnc} — skrypty deklaruja cron bez wpisu"; fi
  if [ "${_tmi:-0}" = "0" ]; then ok "CronTargetMissing = 0"; else bad "CronTargetMissing = ${_tmi} — wpisy cron wskazuja nieistniejace cele"; fi
  if [ -n "${_lru:-}" ] && [ "$(( _now - _lru ))" -gt 1800 ]; then
    bad "obserwator celow nieaktualny ($(( _now - _lru )) s > 1800 s) — pomiar klamie"
  else
    ok "obserwator celow swiezy ($(( _now - ${_lru:-_now} )) s)"
  fi
else
  bad "brak $_TPROM — brak pomiaru zadeklarowanych/nieodpalanych (obserwator padl?)"
fi

# (d) GLOSNE POMINIETO — zadanie zadeklarowane, ktore w oknie logu ani raz sie
#     nie wykonalo (tylko skip), nie moze pozostac ciche. Klasa „zadeklarowane
#     ale nieodpalane”: QUEUED_COALESCED (per-name lock trzymany ciagle) oraz
#     POMINIETO (glodzenie pasa: limit slotow / back-pressure load-aware).
#     FAIL dopiero przy chronicznym glodzeniu (POMINIETO>=10 i 0 udanych).
_LOG="/var/log/aigon/cron-run.log"
# OKNO CZASOWE (naprawa 2026-10-15): wcześniej ten blok liczył CAŁĄ historię logu,
# więc zadania naprawione tygodnie temu dalej świeciły jako „chroniczne głodzenie"
# — a to fałszywy czerwony, który kosztuje czas Suwerena. Zmierzone: strażnik
# `aigon-alert-sovereign-webhook` miał POMINIETO=6415, ale OSTATNI wpis z 2026-10-05
# (10 dni wcześniej), natomiast `aigon-tunnel-provider-exporter` miał 10 pominięć
# DZISIAJ — i to jest jedyne realne głodzenie. Okno domyślne 24 h
# (AIGON_CRON_STARVE_WINDOW_H), liczone po znaczniku czasu w linii logu.
_WIN_H="${AIGON_CRON_STARVE_WINDOW_H:-24}"
_WINCE="$(date -d "-${_WIN_H} hours" '+%Y-%m-%d %H:%M:%S')"
if [ -r "$_LOG" ]; then
  _skip="$(awk -v wince="$_WINCE" '
    {
      ts = substr($0, 2, 19)   # [YYYY-MM-DD HH:MM:SS] -> "YYYY-MM-DD HH:MM:SS"
      if (ts < wince) next     # poza okna nie liczymy (historia to nie stan)
    }
    $3=="OK"               { ok[$4]=1; next }
    $3 ~ /^RC=/            { ran[$4]=1; next }
    $3=="QUEUED_COALESCED" { c[$4]++; next }
    $3=="POMINIETO"        { p[$4]++; next }
    END { for (n in c) if (!(n in ok) && !(n in ran)) printf "%s:0:%d\n", n, c[n];
          for (n in p) if (!(n in ok) && !(n in ran)) printf "%s:%d:0\n", n, p[n]; }' "$_LOG")"
  _n_coal="$(printf '%s\n' "$_skip" | grep -c ':0:[1-9]' || true)"
  _n_starve="$(printf '%s\n' "$_skip" | grep -cE ':([1-9][0-9]*):0$' || true)"
  if [ "${_n_coal:-0}" -eq 0 ] && [ "${_n_starve:-0}" -eq 0 ]; then
    ok "brak zadan 'tylko-skip' w oknie logu (kazdy zadeklarowany job ma udany przebieg)"
  else
    warn "zadania TYLKO-SKIP w oknie logu: coalesced=${_n_coal} starved=${_n_starve}"
    while IFS=: read -r _n _p _c; do
      [ -z "$_n" ] && continue
      if [ "${_p:-0}" -ge 10 ]; then
        bad "CHRONICZNE GLODZENIE: $_n — POMINIETO=$_p, udanych 0 (pas zablokowany)"
      else
        warn "tylko-skip: $_n (POMINIETO=${_p:-0} coalesced=${_c:-0})"
      fi
    done < <(printf '%s\n' "$_skip" | head -12)
  fi
else
  warn "brak $_LOG — nie moge zmierzyc cichych skipow (POMINIETO)"
fi

# ── 1. każdy wpis: lock albo waiver ───────────────────────────────────────
LINIE=0
while IFS= read -r line; do
  case "$line" in ''|'#'*|SHELL*|PATH*|MAILTO*) continue ;; esac
  LINIE=$((LINIE+1))
  script="$(printf '%s' "$line" | grep -oE '/opt/PROD/scripts/[A-Za-z0-9._-]+\.(sh|py)' | head -1)"
  [ -z "$script" ] && continue
  base="$(basename "$script")"
  if printf '%s' "$line" | grep -qE 'cron-run\.sh|(^|[^a-z])flock([^a-z]|$)'; then
    continue
  fi
  if [ "${WAIVED[$base]:-0}" = "1" ]; then
    continue
  fi
  # brak locka — sprawdź, czy realnie się kumuluje.
  # UWAGA: `pgrep -fc` potrafi zwrócić WIELE linii (po jednej na dopasowanie
  # wzorca w różnych procesach) — bierzemy PIERWSZĄ i walidujemy liczbę,
  # inaczej `[ "0\n0" -gt 1 ]` = "integer expression expected" (zmierzone).
  n=$(pgrep -fc "$base" 2>/dev/null | head -1 | tr -dc '0-9')
  [ -z "$n" ] && n=0
  if [ "$n" -gt 1 ] 2>/dev/null; then
    bad "$base — BRAK locka i $n rownoleglych instancji TERAZ"
  else
    warn "$base — BRAK locka (nie kumuluje sie w tej chwili, ale ryzyko)"
  fi
done < "$CRON"

# ── 2. kumulacja BIEZACA niezaleznie od locka (nawet z lockiem: >1 to alarm) ─
echo "  --- kumulacja biezaca ---"
CUM=0
for p in /proc/[0-9]*; do
  [ -r "$p/cmdline" ] || continue
  c="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)"
  case "$c" in
    */opt/PROD/scripts/*.sh*|*/opt/PROD/scripts/*.py*)
      b="$(printf '%s' "$c" | grep -oE '/opt/PROD/scripts/[A-Za-z0-9._-]+' | head -1 | xargs -r basename)"
      [ -n "$b" ] && echo "$b" >> /tmp/_clc_names.$$
      ;;
  esac
done
if [ -f /tmp/_clc_names.$$ ]; then
  while read -r b n; do
    if [ "${n:-0}" -gt 2 ]; then
      CUM=$((CUM+1))
      warn "$b — $n instancji rownolegle (>2)"
    fi
  done < <(sort /tmp/_clc_names.$$ | uniq -c | awk '{print $2, $1}')
  rm -f /tmp/_clc_names.$$
fi

# ── 2b. WYKONANIE: lock zielony != zadanie wykonane (RC=127) ──────────────
# ZMIERZONE 2026-09-30: bramka pilnowała tylko OBECNOŚCI locka, a zadania
# i tak nie działały — wrapper dostał wywołanie z prefiksem env
# (`cron-run.sh X 600 -- VAR=1 bash ...`), próbował wykonać `VAR=1` jako
# komendę i zwracał RC=127 (command not found) CO 2 MINUTY. 34 wystąpienia
# w /var/log/aigon/cron-run.log, a bramka była ZIELONA — czyli fałszywy
# zielony klasy „lock jest, pracy nie ma". Teraz bramka czyta własny log
# wykonania i FAIL-uje, gdy skrypt powtarzalnie nie startuje.
CLR_LOG="${AIGON_CRON_RUN_LOG:-/var/log/aigon/cron-run.log}"
if [ -r "$CLR_LOG" ]; then
  echo "  --- wykonanie (RC=127 = wrapper nie znalazl komendy) ---"
  # OKNO CZASOWE, nie liczba linii: przy 207 wpisach cron log potrafi mieć
  # setki linii na godzinę, więc „ostatnie 500" obejmowało wpisy SPRZED
  # naprawy i bramka krzyczała o historii zamiast o teraźniejszości
  # (zmierzone 2026-09-30: FAIL na skryptach, których ostatnie przebiegi
  # kończyły się OK). Liczymy tylko zdarzenia z ostatnich 30 minut.
  _since="$(date -d '30 minutes ago' '+%Y-%m-%d %H:%M' 2>/dev/null || date '+%Y-%m-%d %H:%M')"
  _bad="$(awk -v s="$_since" '$0 >= "["s' "$CLR_LOG" 2>/dev/null \
          | grep 'RC=127' | sed -E 's/.*RC=127 +([A-Za-z0-9._-]+).*/\1/' \
          | sort | uniq -c | awk '$1 >= 2 {print $2}' || true)"
  # WERYFIKACJA "czy to jeszcze zywe": wpis RC=127 sprzed naprawy leży w oknie
  # 30 min i sam z siebie NIE dowodzi regresji. Bramka patrzy dodatkowo na
  # NAJŚWIEŻSZY wpis danego skryptu — jeśli jest OK/POMINIETO, problem jest
  # historyczny i NIE blokujemy (inaczej bramka krzyczy o naprawionym).
  _real=""
  if [ -n "$_bad" ]; then
    while read -r b; do
      [ -z "$b" ] && continue
      _last="$(grep -E " (OK|POMINIETO|RC=|TIMEOUT) +${b}( |$)" "$CLR_LOG" 2>/dev/null | tail -1)"
      case "$_last" in
        *"RC=127"*) _real="$_real $b" ;;
        *) : ;;   # ostatni przebieg NIE byl 127 -> historia, nie regresja
      esac
    done <<< "$_bad"
  fi
  if [ -n "$_real" ]; then
    for b in $_real; do
      bad "$b — RC=127 na NAJSWIEZSZYM przebiegu (zadanie NIE wykonuje sie; sprawdz prefiksy env)"
    done
  else
    ok "brak RC=127 na najswiezszych przebiegach (historia w logu nie blokuje)"
  fi
else
  warn "brak $CLR_LOG — nie moge zmierzyc WYKONANIA (brak dowodu != sukces)"
fi

# ── 3. cele wpisow istnieją ───────────────────────────────────────────────
echo "  --- istnienie celow ---"
MISS=0
while IFS= read -r line; do
  case "$line" in ''|'#'*|SHELL*|PATH*|MAILTO*) continue ;; esac
  for f in $(printf '%s' "$line" | grep -oE '/opt/PROD/[A-Za-z0-9._/-]+\.(sh|py)'); do
    if [ ! -f "$f" ]; then
      bad "cel nie istnieje: $f"
      MISS=$((MISS+1))
    fi
  done
done < "$CRON"
[ "$MISS" -eq 0 ] && ok "wszystkie cele wpisow istnieja"

# ── wynik ─────────────────────────────────────────────────────────────────
echo "== RESULT == FAIL=$FAILS WARN=$WARNS wpisow=$LINIE kumulacji=$CUM"
if [ "$FAILS" -gt 0 ]; then
  echo "cron-lock-check: FAIL — skrypty bez locka ktore sie kumuluja (LAW-Cron-1)"
  exit 1
fi
echo "cron-lock-check: PASS (ostrzezen: $WARNS)"
exit 0
