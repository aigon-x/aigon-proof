#!/usr/bin/env bash
# hermes-verify-otlp-aito.sh — ad-hoc weryfikacja 4 zmienionych plików.
# To NIE jest "suite green" — to dowód skupiony na zmienionej ścieżce.
set -uo pipefail
P=0; F=0
ok(){ echo "  PASS: $1"; P=$((P+1)); }
bad(){ echo "  FAIL: $1"; F=$((F+1)); }

AITO=/opt/PROD/products/drony/aito
OTLP=$AITO/aito-telemetry/src/otlp.rs
AUTH=/opt/PROD/runtime/crates/aigon-runtime/src/auth_guard.rs

echo "=== A. AITO: biblioteka REALNIE obsługuje HTTPS ==="
# 1. Czy parse_endpoint przestał być twardą bramką?
if grep -q 'post_json_https' "$OTLP"; then ok "post_json_https istnieje"; else bad "brak ścieżki HTTPS"; fi
# Sprawdzamy ODRZUCENIE W KODZIE (return Err), nie wzmiankę w komentarzu —
# nagłówek CELOWO cytuje starą regułę jako historię zmiany.
if grep -q 'OTLP przez HTTPS nieobsługiwany' "$OTLP"; then bad "stara odmowa HTTPS nadal w KODZIE"; else ok "stara odmowa HTTPS usunięta z kodu"; fi
# Nagłówek nie może kłamać: musi mówić, że OBA tryby są obsługiwane.
if grep -q 'Obsługiwane.*OBA\|OBA.*tryby' "$OTLP"; then ok "nagłówek zgodny z kodem (OBA tryby)"; else bad "nagłówek nie mówi o obu trybach"; fi
# 2. Kluczowy element z wzorca runtime
if grep -q 'pool_max_idle_per_host(0)' "$OTLP"; then ok "pool_max_idle_per_host(0) (wzorzec rustls↔Go)"; else bad "brak pool_max_idle — bad record MAC wróci"; fi
# 3. CA w formacie wymaganym
if grep -q 'AITO_TLS_CA_CERT' "$OTLP" && grep -q 'AIGON_TLS_CA_CERT' "$OTLP"; then ok "CA: AITO_TLS_CA_CERT -> AIGON_TLS_CA_CERT"; else bad "brak łańcucha CA"; fi
# 4. Zależność zadeklarowana w TYM workspace (aito ma WŁASNY)
if grep -q '^reqwest' "$AITO/Cargo.toml"; then ok "reqwest w [workspace.dependencies] aito"; else bad "reqwest nie zadeklarowany w workspace aito"; fi
if grep -q 'reqwest.workspace = true' "$AITO/aito-telemetry/Cargo.toml"; then ok "aito-telemetry: reqwest.workspace"; else bad "brak reqwest w crate"; fi

echo "=== B. AITO: kompilacja + testy (REALNY dowód, nie grep) ==="
cd "$AITO"
if cargo check -p aito-telemetry >/tmp/hv-check.log 2>&1; then ok "cargo check PASS"; else bad "cargo check FAIL"; tail -5 /tmp/hv-check.log; fi
if cargo test -p aito-telemetry >/tmp/hv-test.log 2>&1; then
  N=$(grep -oE '[0-9]+ passed' /tmp/hv-test.log | head -1)
  ok "cargo test PASS ($N)"
else bad "cargo test FAIL"; tail -8 /tmp/hv-test.log; fi

echo "=== C. AITO: wdrożenie na żywym kontenerze ==="
if docker ps --format '{{.Names}}' | grep -q '^deploy-console-1$'; then
  E=$(docker inspect deploy-console-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)
  grep -q 'AITO_OTLP_ENDPOINT=https://' <<<"$E" && ok "endpoint HTTPS w env" || bad "endpoint nie-HTTPS"
  grep -q 'AIGON_TLS_CA_CERT=' <<<"$E" && ok "CA w env" || bad "brak CA w env"
  M=$(docker inspect deploy-console-1 --format '{{range .Mounts}}{{.Source}}|{{end}}' 2>/dev/null)
  grep -q 'core/tls/ca.crt' <<<"$M" && ok "CA zamontowane :ro" || bad "brak mountu CA"
  grep -q 'healthy' <<<"$(docker inspect deploy-console-1 --format '{{.State.Health.Status}}' 2>/dev/null)" && ok "kontener healthy" || bad "kontener niehealthy"
else bad "deploy-console-1 nie działa"; fi

echo "=== D. RUNTIME: helper secret_env_or_file ==="
if grep -q 'pub fn secret_env_or_file' "$AUTH"; then ok "helper istnieje"; else bad "brak helpera"; fi
# Kolejność env>plik (kluczowa dla dual-run)
SEC=$(sed -n '/pub fn secret_env_or_file/,/^}/p' "$AUTH")
if grep -q 'env::var(var)' <<<"$SEC"; then ok "czyta env jako pierwsze"; else bad "zła kolejność (env musi wygrywać)"; fi
if grep -q '{var}_FILE' <<<"$SEC"; then ok "obsługuje {VAR}_FILE"; else bad "brak wariantu _FILE"; fi
if grep -q 'istnieje, ale jest pusty' <<<"$SEC"; then ok "pusty plik != sukces (jawny warn)"; else bad "pusty plik cicho zwraca None"; fi

echo "=== E. RUNTIME: kompilacja crate'a z helperem ==="
cd /opt/PROD
if timeout 500 cargo check -p aigon-runtime >/tmp/hv-rt.log 2>&1; then ok "cargo check -p aigon-runtime PASS"; else bad "cargo check FAIL"; tail -6 /tmp/hv-rt.log; fi

echo
echo "=================================================="
echo "WYNIK: $P PASS / $F FAIL"
echo "=================================================="
exit "$F"
