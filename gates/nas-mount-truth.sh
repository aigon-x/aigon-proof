#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  nas-mount-truth.sh — BRAMKA PRAWDY MONTAŻU NAS
#  Kanon: config/canonical/nas-mount-truth.yaml (2026-10-16, rozkaz Suwerena)
#
#  ZASADA: autofs != zamontowane. Prawda = sshfs ze ZRODLA MESHA (100.x)
#          ORAZ katalog oddaje tresc. Sam autofs = FAIL (falszywy zielony).
#
#  DLACZEGO: incydent 2026-10-16 — /etc/fstab montowal NAS po LAN
#  192.168.0.100 (martwy poza siecia lokalna), a `mount` pokazywal autofs,
#  wiec kazda sonda "czy jest mount?" mowila PASS. Szpieg tego nie widzial,
#  bo mial 9 spraw bez wymiaru montazu.
#
#  UZYCIE: bash tools/gates/nas-mount-truth.sh [/mnt/nas]
#  EXIT:   0 = PASS, 1 = FAIL
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

TARGET="${1:-/mnt/nas}"

fail() { echo "nas-mount-truth: FAIL — $*" >&2; exit 1; }
pass() { echo "nas-mount-truth: PASS — $*"; exit 0; }

command -v findmnt >/dev/null 2>&1 || fail "brak findmnt (util-linux) — nie moge zmierzyc"

SRC="$(findmnt -no SOURCE --target "$TARGET" 2>/dev/null | tail -1 || true)"
FSTYPE="$(findmnt -no FSTYPE --target "$TARGET" 2>/dev/null | tail -1 || true)"

# 1) czy w ogole jest montaz
[ -n "${SRC:-}" ] || fail "$TARGET: brak montazu (pusto)"

# 2) sam autofs = NIE zamontowane (kluczowy falszywy zielony)
if [ "${FSTYPE:-}" = "autofs" ]; then
  fail "$TARGET: sam autofs (placeholder) — NAS NIE zamontowany; piec 'mounted' nie jest dowodem"
fi
[ -n "${FSTYPE:-}" ] || fail "$TARGET: nieznany fstype (pusto)"

# 3) musi to byc sshfs
case "$FSTYPE" in
  fuse.sshfs|sshfs) : ;;
  *) fail "$TARGET: fstype=$FSTYPE (oczekiwano fuse.sshfs)" ;;
esac

# 4) zrodlo MUSI byc adresem mesha (100.x) — zakaz LAN (192.168.x)
if printf '%s' "$SRC" | grep -qE '(^|@)100\.[0-9]+\.[0-9]+\.[0-9]+:'; then
  :
else
  fail "$TARGET: zrodlo '$SRC' NIE jest adresem mesha (100.x) — ZAKAZ LAN, patrz kanon nas-mount-truth.yaml"
fi

# 5) musi realnie serwowac tresc (odczyt katalogu)
if timeout 20 ls "$TARGET" >/dev/null 2>&1; then
  :
else
  fail "$TARGET: nie oddaje tresci (odczyt katalogu padl/timeout) — mount-widmo"
fi

pass "$TARGET: sshfs z $SRC, oddaje tresc"
