#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/ca-bundle-public-roots.sh — gate CA-BUNDLE-PUBLIC-ROOTS
#
#  KLASA DEFEKTU (LAW-DEFECT-TO-GATE-1, zmierzone 2026-10-17):
#    kontener ustawia SSL_CERT_FILE / REQUESTS_CA_BUNDLE na plik z SAMYM
#    wewnetrznym CA AIGON (core/tls/ca.crt, 1 cert). Klienci Pythona
#    (httpx, requests, urllib/OpenSSL) traca wtedy publiczne rooty i KAZDE
#    wyjscie na publiczny HTTPS pada CERTIFICATE_VERIFY_FAILED — a /health
#    dalej swieci na zielono.
#    Precedens: monai-kaggle od lataki GATE-135 (2026-10-02) do 2026-10-17
#    nie pobral ani jednego konkursu (tory api+scrape = ERROR).
#    Skan 2026-10-17: 14 plikow compose, >20 serwisow z tym wzorcem.
#
#  CO MIERZY: dla kazdego DZIALAJACEGO kontenera z SSL_CERT_FILE lub
#    REQUESTS_CA_BUNDLE w env — liczbe certyfikatow w tym pliku WEWNATRZ
#    kontenera. < CA_MIN_CERTS (def. 2) = brak publicznych rootow = FAIL.
#    Poprawny wzorzec: /opt/PROD/core/tls/ca-bundle.crt (system + AIGON CA).
#
#  KONTRAKT: exit 0 = PASS, exit 1 = FAIL. Metryka textfile (gdy katalog
#    istnieje): aigon_ca_bundle_no_public_roots{container}.
#  Env: CA_MIN_CERTS (def. 2), CA_GATE_ALLOW (lista kontenerow rozdzielona
#    spacjami — swiadome wyjatki, np. serwis mowiacy tylko do mesha).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
export PATH="/usr/bin:/usr/local/bin:$PATH"

MIN="${CA_MIN_CERTS:-2}"
ALLOW=" ${CA_GATE_ALLOW:-} "
TEXTFILE_DIR="${AIGON_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

fails=0; checked=0; skipped=0; lines=""
for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
  case "$ALLOW" in *" $c "*) continue ;; esac
  for var in SSL_CERT_FILE REQUESTS_CA_BUNDLE; do
    f=$(docker inspect "$c" -f '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | sed -n "s/^${var}=//p" | head -1)
    [ -z "$f" ] && continue
    # Klasa dotyczy klientow Pythona (OpenSSL honoruje SSL_CERT_FILE). Node/Rust/Go
    # i obrazy distroless tej zmiennej nie czytaja albo nie maja interpretera —
    # wtedy SKIP, nie FAIL (inaczej bramka klamie czerwienia na sprawnym serwisie).
    n=$(timeout 15 docker exec "$c" python3 -c "import ssl;print(len(ssl.create_default_context().get_ca_certs()))" 2>/dev/null | tr -dc '0-9')
    if [ -z "$n" ]; then
      skipped=$((skipped+1)); break
    fi
    checked=$((checked+1))
    bad=0
    if [ "$n" -lt "$MIN" ]; then
      printf '       FAIL: %s %s=%s python laduje %s CA — brak publicznych rootow\n' "$c" "$var" "$f" "$n"
      fails=$((fails+1)); bad=1
    fi
    lines+="aigon_ca_bundle_no_public_roots{container=\"$c\",var=\"$var\"} $bad"$'\n'
    break   # jeden wpis na kontener wystarczy (oba wskazuja zwykle ten sam plik)
  done
done

if [ -d "$TEXTFILE_DIR" ] && [ -w "$TEXTFILE_DIR" ]; then
  tmp="$TEXTFILE_DIR/.ca_bundle_public_roots.prom.$$"
  {
    echo "# HELP aigon_ca_bundle_no_public_roots 1 = SSL_CERT_FILE/REQUESTS_CA_BUNDLE bez publicznych rootow"
    echo "# TYPE aigon_ca_bundle_no_public_roots gauge"
    printf '%s' "$lines"
    echo "# HELP aigon_ca_bundle_gate_last_run_timestamp Ostatni przebieg bramki"
    echo "# TYPE aigon_ca_bundle_gate_last_run_timestamp gauge"
    echo "aigon_ca_bundle_gate_last_run_timestamp $(date +%s)"
  } > "$tmp" && mv -f "$tmp" "$TEXTFILE_DIR/ca_bundle_public_roots.prom"
fi

printf '       python+CA w env: %s, SKIP (bez pythona): %s, FAIL: %s\n' "$checked" "$skipped" "$fails"
[ "$fails" -eq 0 ]
