#!/bin/bash
# preflight-slurm-sbatch.sh — ad-hoc weryfikacja skryptów SLURM PRZED wysłaniem.
#
# KLASA: job na klastrze HPC (Leonardo/CINECA, ale kontrole są ogólne) pada po
# ~2 minutach na rzeczy, którą dało się wykryć STATYCZNIE. Każdy job kosztuje
# kolejkę + okno alokacji, więc preflight jest tańszy niż trzeci FAIL z rzędu.
#
# Wszystkie kontrole pochodzą ze ZMIERZONYCH awarii (2026-09-28):
#   job 58923570 FAILED 00:01:52 — pip install na węźle compute:
#                                  "Network is unreachable" (compute bez internetu)
#   job 58931279 FAILED 00:02:14 — "--trainer.checkpoint_epochs": unrecognized
#                                  (flaga z INNEJ wersji; nie zgaduj flag)
#   job 58936461 FAILED           — torch 2.6+ weights_only=True + pathlib.PosixPath
#                                  (checkpoint ze starszej wersji)
#
# UŻYCIE:
#   bash preflight-slurm-sbatch.sh <plik1.sbatch> [plik2.sbatch ...]
#   bash preflight-slurm-sbatch.sh            # domyślnie: wszystkie *.sbatch w CWD
# Wyjście: 0 = OK, N = liczba naruszeń. Każde naruszenie z numerem linii.
#
# KONTROLA NEGATYWNA (obowiązkowa przy zmianie tego skryptu):
#   printf '%s\n' '#!/bin/bash' '#SBATCH --partition=lrd_all_serial' \
#     'pip install torch' 'python -m x fit --trainer.checkpoint_epochs 50' > /tmp/bad.sbatch
#   bash preflight-slurm-sbatch.sh /tmp/bad.sbatch    # oczekiwane: FAIL > 0
set -uo pipefail

FILES=("$@")
if [ "${#FILES[@]}" -eq 0 ]; then
  mapfile -t FILES < <(ls -1 ./*.sbatch 2>/dev/null)
fi
[ "${#FILES[@]}" -gt 0 ] || { echo "brak plików .sbatch do sprawdzenia"; exit 2; }

FAIL=0
chk() { # chk <opis> <plik> <regex> [min=1]
  local n="$1" f="$2" pat="$3" want="${4:-1}" got
  got=$(grep -cE "$pat" "$f" 2>/dev/null || echo 0)
  if [ "$got" -ge "$want" ]; then echo "  PASS $n ($got)"
  else echo "  FAIL $n (jest $got, chce >=$want)"; FAIL=$((FAIL+1)); fi
}
# Wzorzec NIE MOŻE wystąpić JAKO WYWOŁANIE. Komentarz dokumentujący pułapkę jest
# legalny (a często konieczny) — dlatego odsiewamy komentarze i echo/printf.
# Patrz skill verification-guard-integrity §3.1/§3.1f: kontrola „brak X" jest
# z definicji kontrolą WYWOŁANIA, nigdy tekstu.
nchk_exec() { # nchk_exec <opis> <plik> <regex komendy>
  local n="$1" f="$2" pat="$3" hits
  hits=$(grep -nE "$pat" "$f" 2>/dev/null \
    | grep -vE '^[0-9]+:\s*#' \
    | grep -vE '^[0-9]+:.*(echo|printf)' || true)
  if [ -n "$hits" ]; then
    echo "  FAIL $n:"; echo "$hits" | sed 's/^/    /'; FAIL=$((FAIL+1))
  else echo "  PASS $n (zero realnych wywołań)"; fi
}

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "=== $f: NIE ISTNIEJE"; FAIL=$((FAIL+1)); continue; }
  echo "=== $(basename "$f") ==="

  bash -n "$f" && echo "  PASS składnia bash" \
    || { echo "  FAIL składnia bash"; FAIL=$((FAIL+1)); }

  # PARTYCJA Z GPU JAWNA. Domyślna partycja klastra często NIE MA GPU — job
  # "przechodzi" na CPU i spala okno alokacji bez ani jednego wyniku z GPU.
  chk "partycja GPU jawna (#SBATCH --partition=...)" "$f" '^#SBATCH --partition='

  # --export=NONE ⇒ job NIE dziedziczy środowiska logowania ⇒ ścieżki literalne.
  chk "--export=NONE" "$f" '^#SBATCH --export=NONE'

  # ASERCJA GPU: bez niej "sukces" może dotyczyć CPU.
  chk "asercja nvidia-smi" "$f" 'nvidia-smi (-L|--query-gpu)'

  # KOLEJNOŚĆ MODUŁÓW: pierwszy musi być ten, od którego zależą pozostałe.
  # Zmierzone: cuda PRZED gcc; gcc z sufiksem (samo "gcc/X.Y.Z" nie wystarcza).
  first_load=$(grep -nE '^module load' "$f" | head -1 | cut -d: -f1 || true)
  if [ -n "$first_load" ]; then
    echo "  INFO pierwszy 'module load' w linii $first_load:"
    sed -n "${first_load}p" "$f" | sed 's/^/    /'
  fi

  # COMPUTE BEZ INTERNETU → zero pip/curl/wget w jobie. Środowisko (venv,
  # zależności, checkpointy, modele) buduj NA LOGIN NODE; job tylko UŻYWA.
  nchk_exec "brak 'pip install' na compute" "$f" '[^a-zA-Z_-]pip[0-9.]* install'
  nchk_exec "brak curl/wget z sieci na compute" "$f" '(curl|wget) .*https?://'

  # ŚCIEŻKI LITERALNE: przy --export=NONE zmienne powłoki są puste w jobie.
  # Job nie może polegać na $WORK/$SCRATCH z sesji logowania.
  if grep -q '^#SBATCH --export=NONE' "$f"; then
    if grep -qE '^\s*(cd|python3?)\s+\$WORK' "$f" && ! grep -qE '^WORK=' "$f"; then
      echo "  FAIL używa \$WORK bez zdefiniowania WORK (export=NONE ⇒ puste)"
      FAIL=$((FAIL+1))
    else
      echo "  PASS \$WORK zdefiniowane lokalnie albo nieużywane"
    fi
  fi

  # ASERCJE WEJŚĆ — job ma KRZYCZEĆ przed startem, gdy brakuje danych/venv.
  chk "asercja istnienia katalogu wyjściowego" "$f" '(mkdir -p|\[ -d )'
done

echo
echo "=== WYNIK: FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && echo "PREFLIGHT: OK" || echo "PREFLIGHT: BŁĘDY (popraw przed sbatch)"
exit "$FAIL"
