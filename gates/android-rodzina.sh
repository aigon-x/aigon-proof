#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  android-rodzina.sh — GATE-141: spójność native Android RODZINY PRODUKTÓW
# ══════════════════════════════════════════════════════════════════════════
#  ROZKAZ Suwerena 2026-09-30: „wszystkie [PWA] robisz jako native android",
#  „wszystkie muszą być wersjonowane", „wszystko musi być idealnie spójne",
#  „dorzuć od razu tą bramkę do bramek runtime", „on nie ma wołać bramki inorg
#  — on ma być UNIWERSALNY dla rodziny".
#
#  Ta bramka jest SAMODZIELNA i UNIWERSALNA: skanuje DRZEWO produktów pod
#  podanym korzeniem, znajduje KAŻDY katalog `*/android/app/build.gradle.kts`
#  i weryfikuje spójność wzorca rodziny. NIE woła żadnej bramki inorg — ma
#  własną logikę, więc działa dla dowolnej rodziny (INORG, produkty PROD,
#  przyszłe rodziny).
#
#  Weryfikuje per produkt:
#    W1 STRUKTURA   — android/app/build.gradle.kts + AndroidManifest.xml
#    W2 WERSJONOWANIE — versionCode ORAZ versionName (rozkaz wprost)
#    W3 TOŻSAMOŚĆ   — applicationId obecny
#    W4 MANIFEST    — <application> + <activity> + android:exported (wymóg A12+)
#    W5 CZYSTOŚĆ    — brak resztek innego produktu (kod nie wycieka między produktami)
#
#  Użycie:
#    bash android-rodzina.sh                          # korzeń domyślny
#    AIGON_RODZINA_ROOT=/opt/projects/inorg bash android-rodzina.sh
#    bash android-rodzina.sh /sciezka/do/rodziny
#  Exit: 0 = wszyscy zgodni; 1 = co najmniej jeden odstaje; 0 z SKIP gdy brak drzewa.
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="${1:-${AIGON_RODZINA_ROOT:-/opt/projects/inorg}}"

# Produkty WYŁĄCZONE z wymogu native (rozkaz: drony zostają w przeglądarce).
WYLACZONE_RE='^(drony|_archive|node_modules|target|build|\.git)$'

PASS=0; FAIL=0; PRODUKTY_Z_ANDROID=0

if [ ! -d "$ROOT" ]; then
  echo "SKIP android-rodzina: brak korzenia $ROOT (brak danych != złamanie)"
  exit 0
fi

# Znajdź produkty: katalog z android/app/build.gradle.kts
mapfile -t KANDYDACI < <(
  # DWIE KONWENCJE KATALOGU (zmierzone 2026-09-30): nowsze produkty maja
  # `android/`, ale phoneguard ma `agent/` (217 odwolan w deploy/releases —
  # zmiana nazwy bylaby destrukcyjna). Spójność DANYCH (versioning/manifest)
  # jest wazniejsza niz nazwa katalogu, wiec bramka rozpoznaje OBIE.
  find "$ROOT" -maxdepth 4 \( -path '*/android/app/build.gradle.kts' -o -path '*/agent/app/build.gradle.kts' \) \
       -not -path '*/node_modules/*' -not -path '*/_archive/*' -not -path '*/build/*' -not -path '*/spike/*' 2>/dev/null | sort
)

if [ "${#KANDYDACI[@]}" -eq 0 ]; then
  echo "SKIP android-rodzina: brak produktów z android/ pod $ROOT (brak danych != złamanie)"
  exit 0
fi

echo "=== GATE-141: spójność native Android rodziny (root=$ROOT) ==="
for GRADLE in "${KANDYDACI[@]}"; do
  ANDROID_DIR="$(dirname "$(dirname "$GRADLE")")"     # .../<produkt>/android
  PRODUKT="$(basename "$(dirname "$ANDROID_DIR")")"    # <produkt>
  case "$PRODUKT" in $WYLACZONE_RE) continue;; esac
  PRODUKTY_Z_ANDROID=$((PRODUKTY_Z_ANDROID+1))
  echo ""
  echo "--- $PRODUKT ---"

  # W1 STRUKTURA
  # GLOWNY manifest: app/src/main/AndroidManifest.xml. NIE pierwszy z brzegu —
  # produkty maja OVERLAYE (managed/consumer/debug), ktore nie zawieraja
  # <activity> (dziedzicza z main). Zmierzone 2026-09-30: phoneguard ma 5
  # manifestow, a naiwne `head -1` trafialo w overlay => falszywy FAIL W4.
  MANIFEST="$ANDROID_DIR/app/src/main/AndroidManifest.xml"
  [ -f "$MANIFEST" ] || MANIFEST=$(find "$ANDROID_DIR" -name "AndroidManifest.xml" 2>/dev/null | grep -v '/managed/\|/consumer/\|/debug/' | head -1)
  if [ -n "$MANIFEST" ]; then
    PASS=$((PASS+1)); echo "  PASS  W1 struktura (build.gradle.kts + manifest)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  W1 brak AndroidManifest.xml"
  fi

  # W2 WERSJONOWANIE
  VC=$(grep -oE 'versionCode\s*=\s*[0-9]+' "$GRADLE" | head -1)
  VN=$(grep -oE 'versionName\s*=\s*"[^"]*"' "$GRADLE" | head -1)
  if [ -n "$VC" ] && [ -n "$VN" ]; then
    PASS=$((PASS+1)); echo "  PASS  W2 wersjonowanie ($VC, $VN)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  W2 brak wersjonowania (versionCode='${VC:-}' versionName='${VN:-}')"
  fi

  # W3 TOŻSAMOŚĆ
  AID=$(grep -oE 'applicationId\s*=\s*"[^"]+"' "$GRADLE" | head -1)
  if [ -n "$AID" ]; then
    PASS=$((PASS+1)); echo "  PASS  W3 applicationId ($AID)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  W3 brak applicationId"
  fi

  # W4 MANIFEST
  if [ -n "$MANIFEST" ]; then
    APP=$(grep -c '<application' "$MANIFEST")
    ACT=$(grep -c '<activity' "$MANIFEST")
    EXP=$(grep -c 'android:exported' "$MANIFEST")
    if [ "$APP" -ge 1 ] && [ "$ACT" -ge 1 ] && [ "$EXP" -ge 1 ]; then
      PASS=$((PASS+1)); echo "  PASS  W4 manifest (application+activity+exported)"
    else
      FAIL=$((FAIL+1)); echo "  FAIL  W4 manifest niekompletny (app=$APP act=$ACT exported=$EXP)"
    fi
  fi

  # W5 CZYSTOŚĆ — kod nie importuje PAKIETU innego produktu (wyciek wzorca).
  # PUŁAPKA (zmierzona 2026-09-30): naiwne grep po nazwie produktu daje FAŁSZYWY
  # ALARM — "gem" jest podciągiem "gem-vault", a "arka" bywa fragmentem innych
  # słów. Detektor MUSI porównywać PEŁNE identyfikatory pakietów (applicationId),
  # nie dowolne nazwy. Sprawdzamy, czy w kodzie występuje `package` lub `import`
  # wskazujący na pakiet INNEGO produktu rodziny.
  KDIR="$ANDROID_DIR/app/src/main"
  if [ -d "$KDIR" ]; then
    OBCE=0
    for INNY in "${KANDYDACI[@]}"; do
      INA="$(dirname "$(dirname "$INNY")")"; INP="$(basename "$(dirname "$INA")")"
      [ "$INP" = "$PRODUKT" ] && continue
      case "$INP" in $WYLACZONE_RE) continue;; esac
      IGRADLE="$INNY"
      IPKG=$(grep -oE 'applicationId\s*=\s*"[^"]*"' "$IGRADLE" | head -1 | grep -oE '"[^"]*"' | tr -d '"')
      [ -z "$IPKG" ] && continue
      # Version checkouts share an immutable published application identity;
      # directory names do not make that same package a foreign product.
      OWN_PKG=$(printf '%s' "$AID" | grep -oE '"[^"]*"' | tr -d '"')
      [ "$IPKG" = "$OWN_PKG" ] && continue
      # Szukaj PEŁNEGO pakietu (z kropkami) w package/import, nie nazwy produktu.
      # DEFEKT ZMIERZONY 2026-09-30 (fałszywy FAIL blokujący commit):
      # wzorzec `(package|import)\s+$IPKG` BEZ GRANICY identyfikatora dopasowywał
      # PAKIETY BĘDĄCE PREFIKSEM, np. IPKG=`ai.inorg.gem` łapał kod produktu
      # gem-vault (`package ai.inorg.gemvault.ui`) — produkt oskarżał SAM SIEBIE.
      # Zmierzone: gem=ai.inorg.gem, gem-vault=ai.inorg.gemvault; bramka
      # raportowała "kod importuje pakiet innego produktu: ai.inorg.gem"
      # w gem-vault, gdzie WSZYSTKIE importy są własne.
      # Fix: granica po IPKG = kropka albo koniec identyfikatora (`.` lub `/`/koniec
      # linii), więc `ai.inorg.gem` NIE dopasuje `ai.inorg.gemvault`.
      # UWAGA: kropka w grep -E to DOWOLNY znak — escapujemy ją w IPKG.
      IPKG_RE="$(printf '%s' "$IPKG" | sed 's/\./\\./g')"
      if grep -rqE "(package|import)[[:space:]]+$IPKG_RE([.]|[[:space:]]|$)" "$KDIR" 2>/dev/null; then
        OBCE=$((OBCE+1))
        echo "    -> kod importuje pakiet innego produktu: $IPKG"
      fi
    done
    if [ "$OBCE" -eq 0 ]; then
      PASS=$((PASS+1)); echo "  PASS  W5 brak importów pakietów innych produktów"
    else
      FAIL=$((FAIL+1)); echo "  FAIL  W5 kod importuje pakiety $OBCE innych produktów (wzorzec nie wyczyszczony)"
    fi
  fi
done

echo ""
echo "────────────────────────────────────────────────"
echo "produktów z android/: $PRODUKTY_Z_ANDROID"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "GATE-141 android-rodzina: PASS — rodzina spójna"
  exit 0
fi
echo "GATE-141 android-rodzina: FAIL — $FAIL naruszeń (kanon: docs/NATIVE-ANDROID-KANON.md)"
exit 1
