#!/usr/bin/env bash
# GATE-240: STORAGE-TIER-HEALTH — KAŻDY kanoniczny mount (storage + NAS) żyje i jest UŻYWALNY.
#
# POWÓD (zmierzone 2026-10-18, dwa razy z rzędu ten sam błąd):
#   • sprawdzałem JEDEN katalog, a kanonicznych mountów jest 8 (5 tierów NFS + 3 NAS),
#   • `findmnt` pokazuje AUTOF S placeholdery (`systemd-1[...]`) — wyglądają jak
#     osobne/duplikujące mounty, choć to tylko „dociągnę przy dostępie",
#   • /mnt/aigon-repos miał STALE FILE HANDLE (mount wyglądał zdrowo, był martwy),
#   • /mnt/nas-aigonfs był symlinkiem zamiast mountem (drift od fstab bind).
#
# KANON (dwa manifesty, oba czytane):
#   config/canonical/storage-mesh.yaml  → mounts_punkty (tier NFS storage-aigon)
#   config/canonical/nas-mount-truth.yaml → mounts (NAS przez sshfs)
#
# ZASADA POMIARU: mountpoint ≠ dowód. Dowód = REALNY mount (fstype != autofs)
# + zapis + odczyt + SKASOWANIE pliku próbnego. Autofs bez materiału = WARN.
#
# Kontrakt: 0=PASS, 1=FAIL (którykolwiek kanoniczny mount nieużywalny), 2=WARN
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
STORAGE_MANIFEST="${AIGON_STORAGE_MANIFEST:-$ROOT/config/canonical/storage-mesh.yaml}"
NAS_MANIFEST="${AIGON_NAS_MANIFEST:-$ROOT/config/canonical/nas-mount-truth.yaml}"

probe_tier() { # $1=target $2=expected-source-substring $3=label
  local tgt="$1" want="$2" label="$3"
  local fstype src
  # UWAGA (zmierzone 2026-10-19): `findmnt --target` zwraca WIELE linii — pierwsza to
  # autofs-placeholder, realny mount jest WYŻEJ. `head -1` czytał placeholder i bramka
  # była ŚLEPA na własnym układzie (permanentny WARN, zero wykrywalności awarii).
  fstype="$(findmnt -no FSTYPE --target "$tgt" 2>/dev/null | grep -v '^autofs$' | tail -1)"
  src="$(findmnt -no SOURCE --target "$tgt" 2>/dev/null | grep -v '^systemd-1$' | tail -1)"
  if [ -z "$fstype" ]; then
    # autofs dociąga materiał przy dostępie — jeden trigger, potem pomiar ponowny
    ls "$tgt" >/dev/null 2>&1 || true
    sleep 1
    fstype="$(findmnt -no FSTYPE --target "$tgt" 2>/dev/null | grep -v '^autofs$' | tail -1)"
    src="$(findmnt -no SOURCE --target "$tgt" 2>/dev/null | grep -v '^systemd-1$' | tail -1)"
  fi

  if [ -z "$fstype" ]; then
    echo "  FAIL $label $tgt — brak REALNEGO mountu (tylko autofs/brak wpisu)"; return 1
  fi
  if [ -n "$want" ] && ! printf '%s' "$src" | grep -qF "$want"; then
    echo "  FAIL $label $tgt — źródło '$src' != kanon '$want'"; return 1
  fi
  local probe="$tgt/.gate240-$$-$(date +%s)"
  local wok=0
  if printf 'ok' > "$probe" 2>/dev/null && [ "$(cat "$probe" 2>/dev/null)" = "ok" ]; then
    wok=1
  elif id -nG "$(id -un)" 2>/dev/null | grep -qw aigon || getent group aigon >/dev/null; then
    # PITFALL (zmierzone): mount 2775 root:root → user spoza grupy aigon dostaje EACCES.
    # To NIE awaria mountu. Sesja może też mieć nieodświeżone grupy po usermod.
    sg aigon -c "printf ok > '$probe'" 2>/dev/null && [ "$(cat "$probe" 2>/dev/null)" = "ok" ] && wok=1
  fi
  if [ "$wok" = 1 ]; then
    rm -f "$probe" 2>/dev/null
    local used
    used="$(df -P "$tgt" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
    if [ -n "${used:-}" ] && [ "$used" -ge 95 ]; then
      echo "  WARN $label $tgt — zapis OK, zajęte ${used}%"; return 2
    fi
    echo "  PASS $label $tgt — $fstype, zapis+odczyt OK (${used:-?}%)"; return 0
  fi
  echo "  FAIL $label $tgt — mount jest, ale NIEUŻYWALNY (zapis/odczyt): $(printf 'x' > "$probe" 2>&1 | head -1)"
  return 1
}

run_all() {
  local fail=0 warn=0 ok=0 ok_tier=0 rc
  while IFS=$'\t' read -r tgt want; do
    [ -n "${tgt:-}" ] || continue
    probe_tier "$tgt" "$want" "TIER"; rc=$?
    [ "$rc" -eq 0 ] && ok_tier=$((ok_tier+1))
    case $rc in 0) ok=$((ok+1));; 1) fail=$((fail+1));; 2) warn=$((warn+1));; esac
  done < <(python3 - "$STORAGE_MANIFEST" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for m in (d.get("mounts_punkty") or []):
    t, s = m.get("target"), m.get("source")
    if t and s:
        print(f"{t}\t{s}")
PY
)
  while IFS=$'\t' read -r tgt want; do
    [ -n "${tgt:-}" ] || continue
    probe_tier "$tgt" "$want" "NAS"; rc=$?
    case $rc in 0) ok=$((ok+1));; 1) fail=$((fail+1));; 2) warn=$((warn+1));; esac
  done < <(python3 - "$NAS_MANIFEST" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
base = d.get("share") or d.get("base_path") or "share/CACHEDEV1_DATA"
for m in (d.get("mounts") or []):
    t = m.get("target")
    src = m.get("source") or ""
    if t:
        # kanon podaje source z ${tailscale_ip}; bierzemy człon ścieżki po ':'
        want = src.split(":")[-1] if ":" in src else src
        if "${" in want:  # niesubstytuowany szablon (np. ${base_path}) — nie porównujemy
            want = ""
        print(f"{t}\t{want}")
PY
)
  # ── SPÓJNOŚĆ Z METRYKĄ ALERTU (druga definicja TEJ SAMEJ prawdy) ─────────
  # Zmierzone 2026-10-19: bramka naprawiona na autofs, ale PRODUCENT METRYKI
  # (scripts/storage-mesh-mount.sh --check --metric) nie — raportował
  # „unmounted" na sprawdzonych tierach → fałszywy critical
  # StorageTierMountBroken (5 instancji). Ta kontrola nie pozwala im się
  # rozjechać ponownie.
  if [ "$(id -u)" = 0 ]; then
    local mfile mstates
    mfile="$(mktemp)"
    AIGON_STORAGE_METRIC_FILE="$mfile" bash "$ROOT/scripts/storage-mesh-mount.sh" --check --metric >/dev/null 2>&1 || true
    mstates="$(grep -c 'state="ok"' "$mfile" 2>/dev/null || true)"
    rm -f "$mfile"
    if [ "${mstates:-0}" -lt "$ok_tier" ]; then
      echo "  FAIL METRIC scripts/storage-mesh-mount.sh: state=ok dla ${mstates:-0}, bramka zmierzyła $ok_tier tierów NFS — metryka alertu rozjechana z pomiarem"
      fail=$((fail+1))
    else
      echo "  PASS METRIC producent metryki alertu zgodny z pomiarem ($mstates ok)"
    fi
  else
    echo "  SKIP METRIC (cross-check wymaga roota)"
  fi

  echo "mounty: PASS=$ok WARN=$warn FAIL=$fail"
  if [ "$fail" -gt 0 ]; then echo "FAIL storage-tier-health ($fail kanonicznych mountów nieużywalnych)"; return 1; fi
  if [ "$warn" -gt 0 ]; then echo "WARN storage-tier-health ($warn ostrzeżeń)"; return 2; fi
  echo "PASS storage-tier-health (wszystkie kanoniczne mounty zapisywalne)"; return 0
}

if [ "${1:-}" = "--selftest" ]; then
  echo "── SELFTEST GATE-240 (dowod negatywny) ──"
  [ -r "$STORAGE_MANIFEST" ] || { echo "SELFTEST: FAIL (brak manifestu)"; exit 1; }
  listed="$(python3 - "$STORAGE_MANIFEST" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(len(d.get("mounts_punkty") or []))
PY
)"
  echo "[T1] manifest tierów czytany: $listed wpisów (oczekiwane >=5)"
  [ "${listed:-0}" -ge 5 ] || { echo "SELFTEST: FAIL (manifest nie ma tierów)"; exit 1; }

  tmp="$(mktemp -d)"; mkdir -p "$tmp/tier"
  probe_tier "$tmp/tier" "" "SELFTEST" >/dev/null 2>&1; rc_ok=$?
  probe_tier "$tmp/nie-ma" "" "SELFTEST" >/dev/null 2>&1; rc_bad=$?
  echo "[T2] zapisywalny katalog → rc=$rc_ok (oczekiwane 0), nieistniejący → rc=$rc_bad (oczekiwane 1)"
  rm -rf "$tmp"
  [ "$rc_ok" -eq 0 ] && [ "$rc_bad" -eq 1 ] || { echo "SELFTEST: FAIL (bramka slepa)"; exit 1; }
  echo "SELFTEST: PASS (2/2)"
  exit 0
fi

echo "── GATE-240 storage-tier-health ──"
run_all
