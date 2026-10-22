#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/leonardo-hpc-path.sh — BRAMKA ZDROWIA ŚCIEŻKI HPC
#  (CINECA / Leonardo BOOSTER — LAW-CINECA-1)
#
#  PO CO (rozkaz Suwerena 2026-10-13: „wykręcić Cinecę i Leonardo do granic
#  możliwości — to musi być w kanonie, manifeście i prawach"):
#    Pas HPC był monitorowany (queue-guard, endpoint-watchdog, kernel
#    leonardo), ale NIE miał BRAMKI, która jednym werdyktem mówi, czy ścieżka
#    jest ZDROWA. Bez tego „zielone” metryki są deklaracją: cert może wygasnąć,
#    socket agenta przesunąć się, konto zniknąć, a kolejka się zawalić — cicho.
#
#  PASS tylko gdy JEDNOCZEŚNIE:
#    (a) cert SSH ważny   — plik certu istnieje I nie wygasł (ssh-keygen -L),
#    (b) kanał dostępu    — socket agenta SSH żywy LUB ważny cert plikowy
#        (kanał plikowy = kanon od 2026-10-01, działa bez agenta),
#    (c) konto aifac      — konto alokacji aktywne (sacctmgr/sshare; pomiar
#        ŻYWY przez SSH, SKIP gdy klaster chwilowo nieosiągalny),
#    (d) kolejka niezawalona — Slurm sterowalny I kolejka nie w backlogu:
#        aigon_leonardo_slurm_reachable==1, brak training_stall, brak
#        nadmiarowego PENDING (lokalne textfile — pomiar z zebranych metryk).
#
#  TEST NEGATYWNY (kanon: strażnik bez testu negatywnego = tautologia).
#  Każdą sekcję można zapalić env-em:
#    AIGON_LEONARDO_CERT_FILE=<wygasły/brak>          → (a) FAIL
#    AIGON_LEONARDO_SSH_AGENT_SOCK=<zły>              → (b) FAIL gdy brak certu
#    AIGON_LEONARDO_SSH=none                          → (c) SKIP
#    AIGON_LEONARDO_PROM_DIR=<dir z slurm_reachable 0>→ (d) FAIL
#
#  KONTRAKT: exit 0 = PASS/WARN (w tym SKIP), exit 1 = FAIL.
#  Env: --json (raport maszynowy).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JSON=0
[ "${1:-}" = "--json" ] && JSON=1

# Dom operatora = SSOT. Reaktor chodzi jako root (HOME=/root), a hook-runner
# triggera cyclic:hourly jako aigon (HOME=/home/aigon); klucz/cert Cineca zyja
# w domu OPERATORA (kanon: scripts/leonardo-watchdog.sh, leonardo-command-center-snapshot.py,
# aigon-leonardo-exporter.sh uzywaja /home/sniegul). Uzycie $HOME znaczylo, ze
# bramka mierzyla cudze .ssh (nieistniejace) -> FALSZYWA CZERWIEN (FAIL jako
# root/aigon, PASS jako operator). Ta sama klasa co ledger-coverage 2026-10-13 08:00.
HOME_OPER="${AIGON_OPER_HOME:-/home/sniegul}"
CERT="${AIGON_LEONARDO_CERT_FILE:-$HOME_OPER/.ssh/id_cineca_step_ecdsa-cert.pub}"
PROM_DIR="${AIGON_LEONARDO_PROM_DIR:-/var/lib/node_exporter/textfile_collector}"
SSH_MODE="${AIGON_LEONARDO_SSH:-ssh}"          # "none" = pomiń sonda SSH
SSH_TARGET="${AIGON_LEONARDO_SSH_TARGET:-login.leonardo.cineca.it}"
SSH_USER="${AIGON_LEONARDO_SSH_USER:-jsniegoc}"
SSH_KEY="${AIGON_LEONARDO_SSH_KEY:-$HOME_OPER/.ssh/id_cineca_step_ecdsa}"
MAX_PENDING="${AIGON_HPC_MAX_PENDING:-200}"
FORCE_FAIL="${AIGON_HPC_FORCE_FAIL:-}"

fails=0
skips=0
declare -a RESULTS
say() { printf '       %s\n' "$*"; }
mark() { RESULTS+=("$1|$2|$3"); if [ "$2" = "FAIL" ]; then fails=$((fails+1)); elif [ "$2" = "SKIP" ]; then skips=$((skips+1)); fi; }

prom_val() { # plik metryka → ostatnia wartość albo puste
  local f="$PROM_DIR/$1" m="$2"
  [ -r "$f" ] || return 0
  awk -v k="$m" '$1==k {v=$2} END{if(v!="")print v}' "$f" 2>/dev/null
}

# ── (a) cert SSH WAŻNY ─────────────────────────────────────────────────
a_status=FAIL; a_note=""
if [ ! -f "$CERT" ]; then
  a_note="brak pliku certu: $CERT"
elif ! command -v ssh-keygen >/dev/null 2>&1; then
  a_status=SKIP; a_note="brak ssh-keygen — nie mogę zweryfikować ważności"
else
  vline="$(ssh-keygen -L -f "$CERT" 2>/dev/null | awk '/Valid:/{print; exit}')"
  if [ -z "$vline" ]; then
    a_note="cert nieczytelny (ssh-keygen -L): $CERT"
  else
    to="$(printf '%s' "$vline" | sed -E 's/.* to ([0-9T:+-]+).*/\1/')"
    to_epoch="$(date -d "$to" +%s 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ "$to_epoch" -le 0 ]; then
      a_note="nie sparsowałem daty ważności ('$to')"
    elif [ "$to_epoch" -le "$now" ]; then
      a_note="cert WYGASŁ (ważny do $to)"
    else
      a_status=PASS; a_note="cert ważny do $to (za $(( (to_epoch - now) / 3600 )) h)"
    fi
  fi
fi
[ -n "$FORCE_FAIL" ] && [ "$FORCE_FAIL" = "a" ] && { a_status=FAIL; a_note="FORCE_FAIL=a (test negatywny)"; }
mark "(a) cert SSH ważny" "$a_status" "$a_note"

# ── (b) KANAŁ DOSTĘPU: socket agenta LUB ważny cert plikowy ────────────
b_status=FAIL; b_note=""
sock_live=0; sock_path="brak"
if [ -r "$ROOT/scripts/lib/ssh-agent-sock.sh" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/ssh-agent-sock.sh"
  if aigon_ssh_agent_sock 2>/dev/null; then sock_live=1; sock_path="${SSH_AUTH_SOCK:-?}"; fi
else
  cand="${AIGON_LEONARDO_SSH_AGENT_SOCK:-${SSH_AUTH_SOCK:-/run/user/$(id -u)/gcr/ssh}}"
  if [ -S "$cand" ] && SSH_AUTH_SOCK="$cand" ssh-add -l >/dev/null 2>&1; then
    sock_live=1; sock_path="$cand"
  fi
fi
cert_ok=0
if [ -f "$CERT" ] && command -v ssh-keygen >/dev/null 2>&1; then
  vt="$(ssh-keygen -L -f "$CERT" 2>/dev/null | awk '/Valid:/{print; exit}' | sed -E 's/.* to ([0-9T:+-]+).*/\1/')"
  [ -n "$vt" ] && [ "$(date -d "$vt" +%s 2>/dev/null || echo 0)" -gt "$(date +%s)" ] && cert_ok=1
fi
if [ "$sock_live" -eq 1 ] && [ "$cert_ok" -eq 1 ]; then
  b_status=PASS; b_note="socket agenta żywy ($sock_path) I cert plikowy ważny"
elif [ "$sock_live" -eq 1 ]; then
  b_status=PASS; b_note="socket agenta żywy: $sock_path"
elif [ "$cert_ok" -eq 1 ]; then
  b_status=PASS; b_note="socket agenta brak — kanał plikowy (ważny cert) żywy (kanon od 2026-10-01)"
else
  b_note="BRAK socketu agenta I brak ważnego certu plikowego — kanał nie działa"
fi
[ -n "$FORCE_FAIL" ] && [ "$FORCE_FAIL" = "b" ] && { b_status=FAIL; b_note="FORCE_FAIL=b (test negatywny)"; }
mark "(b) kanał dostępu SSH (agent/cert)" "$b_status" "$b_note"

# ── (c) KONTO aifac AKTYWNE (pomiar żywy przez SSH; SKIP gdy sieć padła) ─
c_status=FAIL; c_note=""
if [ "$SSH_MODE" = "none" ]; then
  c_status=SKIP; c_note="SSH wyłączony (AIGON_LEONARDO_SSH=none) — pominięto"
else
  ssh_args=(-o BatchMode=yes -o ConnectTimeout=20 -o ControlMaster=no -o ControlPath=none
            -o NumberOfPasswordPrompts=0 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no
            -o LogLevel=ERROR)
  [ -f "$SSH_KEY" ] && ssh_args+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
  acct_out="$(timeout 45 ssh "${ssh_args[@]}" "$SSH_USER@$SSH_TARGET" \
    'sacctmgr -n -P show assoc user=$USER format=Account 2>/dev/null; echo ---; sshare -U -P 2>/dev/null' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$acct_out" ]; then
    c_status=SKIP; c_note="klaster nieosiągalny (ssh rc=$rc) — pomiar konta pominięty (nie FAIL: sieć != brak konta)"
  elif printf '%s' "$acct_out" | grep -qiE 'aifac'; then
    accts="$(printf '%s' "$acct_out" | grep -oiE 'aifac_[a-z0-9]+' | sort -u | tr '\n' ',')"
    c_status=PASS; c_note="konto aktywne: ${accts%,}"
  else
    c_note="SSH OK, ale konto aifac* NIE występuje w sacctmgr/sshare — konto martwe"
  fi
fi
[ -n "$FORCE_FAIL" ] && [ "$FORCE_FAIL" = "c" ] && { c_status=FAIL; c_note="FORCE_FAIL=c (test negatywny)"; }
mark "(c) konto aifac aktywne" "$c_status" "$c_note"

# ── (d) KOLEJKA NIEZAWALONA (świeże textfile; pomiar z zebranych metryk) ─
#  Uwaga klasyfikacyjna: „zawalona kolejka" (joby nie płyną) != „nieświeży
#  monitoring kolejki". Świeże źródła (leonardo.prom, training.prom) niosą
#  sygnały zawalenia; nieświeżość queue-guard to NOTA (osobny alert ją łapie),
#  nie FAIL tego kryterium — inaczej bramka czerwieni się na martwym
#  monitoringu, choć kolejka jest zdrowa.
d_status=FAIL; d_note=""
slurm_r="$(prom_val aigon-leonardo.prom aigon_leonardo_slurm_reachable)"
stall="$(prom_val aigon-leonardo-training.prom aigon_leonardo_training_stall)"
watch_ok="$(prom_val aigon-leonardo-training.prom aigon_leonardo_training_watch_ok)"
t_ts="$(prom_val aigon-leonardo-training.prom aigon_leonardo_training_last_run_timestamp_seconds)"
stall_note=""
# LAW-HEALTH-1: stary albo slepy snapshot to NIE dowod stallu. Zmierzone
# 2026-10-19: watch_ok=0, a metryki niosly ostatni stall=1; reczny ssh+squeue
# pokazal 0 jobow. Bramka czerwienila sie na martwym monitoringu.
if [ -n "$t_ts" ] && [ "$t_ts" -gt 0 ] 2>/dev/null; then
  t_age=$(( $(date +%s) - t_ts ))
  if [ "$t_age" -gt 1800 ]; then
    stall_note="stall niezmierzony: snapshot ${t_age}s > 1800s"
    stall=""
  fi
fi
if [ "${watch_ok:-0}" != "1" ]; then
  stall_note="stall niezmierzony: watchdog blind (watch_ok=${watch_ok:-?})"
  stall=""
fi
pend="$(prom_val aigon-leonardo-training.prom aigon_leonardo_training_jobs_pending)"
[ -n "$pend" ] || pend="$(prom_val aigon-leonardo-queue.prom aigon_leonardo_queue_pending)"
zjobs="$(prom_val aigon-leonardo-queue.prom aigon_leonardo_cluster_jobs)"
[ -n "$zjobs" ] || zjobs="$(prom_val aigon-leonardo-training.prom aigon_leonardo_training_jobs_running)"
q_ts="$(prom_val aigon-leonardo-queue.prom aigon_leonardo_queue_guard_last_run_timestamp_seconds)"
fresh_note=""
if [ -n "$q_ts" ] && [ "$q_ts" -gt 0 ] 2>/dev/null; then
  q_age=$(( $(date +%s) - q_ts ))
  [ "$q_age" -gt 3600 ] && fresh_note="queue-guard nieświeży (${q_age}s — patrz leonardo-queue-guard.log)"
fi
if [ -z "$slurm_r" ] && [ -z "$stall" ] && [ -z "$pend" ]; then
  d_note="brak textfile kolejki w $PROM_DIR — nie mogę dowieść (nie wiem != OK)"
else
  problems=()
  [ "$slurm_r" = "0" ] && problems+=("slurm_reachable=0")
  [ "$stall" = "1" ] && problems+=("training_stall=1")
  if [ -n "$pend" ] && [ "$pend" -ge 0 ] 2>/dev/null && [ "$pend" -gt "$MAX_PENDING" ]; then
    problems+=("PENDING=$pend > $MAX_PENDING")
  fi
  if [ "${#problems[@]}" -gt 0 ]; then
    d_note="kolejka ZAWALONA: ${problems[*]} (pending=$pend cluster_jobs=$zjobs)"
  else
    d_status=PASS
    d_note="Slurm OK; pending=${pend:-?} cluster_jobs=${zjobs:-?} stall=${stall:-0}${stall_note:+; $stall_note}${fresh_note:+; $fresh_note}"
  fi
fi
[ -n "$FORCE_FAIL" ] && [ "$FORCE_FAIL" = "d" ] && { d_status=FAIL; d_note="FORCE_FAIL=d (test negatywny)"; }
mark "(d) kolejka niezawalona" "$d_status" "$d_note"

# ── RAPORT ─────────────────────────────────────────────────────────────
echo "leonardo-hpc-path: $( [ "$fails" -eq 0 ] && echo PASS || echo FAIL )"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r name st note <<< "$r"
  printf '  [%s] %s — %s\n' "$st" "$name" "$note"
done

# Metryka textfile (LAW-OBS-1): werdykt bramki ma ślad w Prometheusie.
TEXTFILE="$PROM_DIR"
if mkdir -p "$TEXTFILE" 2>/dev/null && [ -w "$TEXTFILE" ]; then
  {
    echo "# HELP aigon_leonardo_hpc_path_gate_pass Werdykt bramki ścieżki HPC (1=PASS, 0=FAIL)"
    echo "# TYPE aigon_leonardo_hpc_path_gate_pass gauge"
    echo "aigon_leonardo_hpc_path_gate_pass $([ "$fails" -eq 0 ] && echo 1 || echo 0)"
    echo "# HELP aigon_leonardo_hpc_path_gate_skips Kryteria pominięte (SKIP)"
    echo "# TYPE aigon_leonardo_hpc_path_gate_skips gauge"
    echo "aigon_leonardo_hpc_path_gate_skips $skips"
    echo "# HELP aigon_leonardo_hpc_path_gate_timestamp_seconds Epoch przebiegu bramki"
    echo "# TYPE aigon_leonardo_hpc_path_gate_timestamp_seconds gauge"
    echo "aigon_leonardo_hpc_path_gate_timestamp_seconds $(date -u +%s)"
  } > "$TEXTFILE/aigon-leonardo-hpc-path-gate.prom.tmp" 2>/dev/null \
    && mv "$TEXTFILE/aigon-leonardo-hpc-path-gate.prom.tmp" "$TEXTFILE/aigon-leonardo-hpc-path-gate.prom" 2>/dev/null
fi

# Span OTel bramki — bramka bez śladu nie istnieje w Tempo.
if [ -r "$ROOT/scripts/lib/otel-span.sh" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/otel-span.sh"
  command -v otel_span_emit >/dev/null 2>&1 && \
    otel_span_emit "aigon-leonardo-hpc-path" "leonardo.hpc_path.gate" \
      pass="$([ "$fails" -eq 0 ] && echo 1 || echo 0)" fails="$fails" skips="$skips" >/dev/null 2>&1 || true
fi

if [ "$JSON" = 1 ]; then
  python3 - "${RESULTS[@]}" <<'PY' 2>/dev/null || true
import json, sys
out = []
for r in sys.argv[1:]:
    name, st, note = r.split("|", 2)
    out.append({"criterion": name, "status": st, "note": note})
print(json.dumps({"gate": "leonardo-hpc-path", "pass": all(x["status"] != "FAIL" for x in out),
                  "criteria": out}, ensure_ascii=False))
PY
fi

[ "$fails" -eq 0 ] && exit 0
exit 1
