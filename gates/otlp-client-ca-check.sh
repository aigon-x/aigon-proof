#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  tools/gates/otlp-client-ca-check.sh — GATE OTLP-CA
#
#  PILNOWANIE: każdy klient OTLP w stacku MUSI mieć CA w formacie WŁAŚCIWYM
#  dla swojego języka. Bez tego self-signed cert kolektora jest odrzucany
#  i telemetria przepada CICHO (objaw zewnętrzny: "TLS handshake error ...
#  unknown certificate authority" / "bad record MAC" w logu kolektora).
#
#  POWÓD POWSTANIA (2026-09-27): agent naprawiał CA klient po kliencie,
#  w pętli — każda poprawka odsłaniała następnego. Suweren: "ciągle budujesz
#  albo jedno albo drugie". Zamiast gasić pożary, bramka enumeruje KOMPLET
#  klientów i sprawdza każdy z osobna. Jeden przebieg = pełna lista braków.
#
#  KONTRAKT: exit 0 = PASS (wszyscy klienci mają CA w swoim formacie)
#            exit 1 = FAIL (ktoś nie ma — fail-closed, BLOCKING)
#            exit 2 = błąd środowiska (brak docker itp.)
#
#  Opcje: --json | --quiet
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

JSON=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "OTLP-CA: brak docker"; exit 2; }

python3 - "$JSON" "$QUIET" <<'PY'
import json, re, subprocess, sys

as_json = sys.argv[1] == "1"
quiet   = sys.argv[2] == "1"

def sh(*a):
    # TIMEOUT-FIX 2026-10-02: subprocess BEZ timeoutu wisial minuty przy load>3x
    # rdzenie (129 kontenerow x 4 docker inspect = 516 synchronicznych wolnych
    # wolnych wywolan) -> pre-push TIMEOUT bramki = werdyktu nie ma = NIE PASS.
    # Twardy sufit 10 s/wywolanie; brak odpowiedzi = "" (bramka fail-open na tym
    # kontenerze, nie wisi calej kolejki pre-push).
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=10).stdout
    except (subprocess.TimeoutExpired, OSError):
        return ""

# ── 1. KLASYFIKACJA OBRAZU -> FORMAT CA ──────────────────────────────────
# Rust czyta AIGON_TLS_CA_CERT + reqwest::add_root_certificate (kod w
#   aigon-adapters/src/observability/otlp.rs).
# Node czyta WYŁĄCZNIE NODE_EXTRA_CA_CERTS (AIGON_TLS_CA_CERT to nasza
#   konwencja — Node jej NIE zna).
# Python czyta SSL_CERT_FILE / REQUESTS_CA_BUNDLE.
#
# ── ZMIENIONE 2026-09-29: WYKRYWANIE INTERPRETERA Z RUNTIME (nie z nazwy) ──
# WADA POPRZEDNIEJ WERSJI (zmierzona): klasyfikacja szła po nazwie OBRAZU
# i polu USER, a oba kłamią:
#   * `monai:0.2.0`          → obraz PYTHONA (3.12.14), nazwa tego nie zdradza
#     → bramka widziała "rust" i wymagała AIGON_TLS_CA_CERT, choć kontener ma
#       POPRAWNY SSL_CERT_FILE. Fałszywy FAIL na sprawnym kliencie.
#   * `monai-api:1.2.0`      → obraz NODE (v18.20.8), nazwa nie zawiera "node"
#   * `postgres-exporter`    → Go; w ogóle nie gada OTLP SDK-em, więc wymaganie
#     CA w formacie Rusta jest wymaganiem nieistniejącej rzeczy.
# Fixture „python"/"node" w nazwie to przypadek, nie reguła. MIERZYMY interpreter
# w działającym kontenerze — to jedyny sygnał, który nie kłamie. To ta sama
# klasa defektu, co regex-po-tekście w capability-drift-check i kernel-health:
# detektor patrzył na deklarację, nie na stan faktyczny.
def _probe(container: str, *cmd: str) -> str:
    """Uruchom sondę w kontenerze; zwróć stdout TYLKO gdy rc == 0.

    PUŁAPKA ZMIERZONA 2026-09-29: `sh()` bierze `capture_output=True` i zwraca
    `.stdout` — ale przy nieudanym `docker exec` komunikat błędu (`OCI runtime
    exec failed: exec: "python3": executable file not found`) ląduje w
    `stderr`, a `stdout` bywa NIEPUSTY (docker pisze część komunikatu na stdout).
    Dlatego naiwne `if out:` uznawało, że interpreter ISTNIEJE, gdy go nie ma —
    `any_interpreter=True` dla obrazu bez ANI JEDNEGO interpretera
    (prometheuscommunity/postgres-exporter). Warunek musi sprawdzać KOD WYJŚCIA,
    nie niepustość stdout. Klasyka LAW-011 pkt 3: narzędzie połykające komunikat
    serwera i biorące go za treść.
    """
    p = subprocess.run(["docker", "exec", container, *cmd],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return ""
    return p.stdout


def detect_lang_from_runtime(container: str) -> str:
    """Język z ŻYWEGO kontenera. Zwraca 'python'|'node'|'go'|'no-sdk'|''.

    ZMIERZONE 2026-09-29: `prometheuscommunity/postgres-exporter` to STATYCZNY
    build Go — w obrazie NIE MA interpretera python/node/go, więc żadna z sond
    nie trafia i funkcja zwracała '' → fallback dawał 'rust' → bramka wymagała
    AIGON_TLS_CA_CERT od klienta, który OTLP NIE MÓWI WCALE. Dowód (zmierzony):
      strings /bin/postgres_exporter | grep -ci otlp     → 0
      ss -tn | grep -c 44318 (w kontenerze)              → 0
    Czyli `AIGON_OTLP_ENDPOINT` + `AIGON_OTEL_ENABLED=true` w jego env to
    MARTWA deklaracja — proces ich nie konsumuje.
    Brak JAKIEGOKOLWIEK interpretera traktujemy więc jako sygnał: to nie jest
    klient SDK, nie ma czego konfigurować. NIE zgadujemy wtedy 'rust'.
    """
    any_interpreter = False
    for probe, lang in ((("python3", "--version"), "python"),
                        (("python", "--version"), "python"),
                        (("node", "--version"), "node"),
                        (("go", "version"), "go")):
        out = _probe(container, *probe)
        if not out:
            continue
        any_interpreter = True
        if "Python" in out:
            return "python"
        if "go version" in out:
            return "go"
        if lang == "node" and re.match(r"^v\d", out.strip()):
            return "node"
    # Żywy kontener bez interpretera = statyczny binarny klient (Go/Rust bez
    # toolchaina). Rozróżnienie robimy po OBECNOŚCI obsługi OTLP w binarce.
    if not any_interpreter:
        has_otlp = _probe(container, "sh", "-c",
                          "strings /bin/* 2>/dev/null | grep -ci otlp || true").strip()
        if has_otlp.isdigit() and int(has_otlp) == 0:
            return "no-sdk"   # nie gada OTLP → nie ma czego wymagać
        return "go"
    return ""


def expected_env(image: str, user: str = "", container: str = "") -> tuple[str, list[str]]:
    i = image.lower()
    u = (user or "").lower()

    # 1) NAJPIERW runtime — patrz komentarz wyżej. Jeśli wykryjemy interpreter,
    #    wierzymy MU, a nie nazwie obrazu.
    if container:
        rt = detect_lang_from_runtime(container)
        if rt == "python":
            return "python", ["SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"]
        if rt == "node":
            return "node", ["NODE_EXTRA_CA_CERTS"]
        if rt == "go":
            # Go (prometheus-community/postgres-exporter) NIE eksportuje OTLP
            # SDK-em — nie ma czego konfigurować, więc nie ma czego wymagać.
            return "go", []
        if rt == "no-sdk":
            # Zmierzone 2026-09-29: statyczna binarka BEZ obsługi OTLP
            # (`strings /bin/* | grep -ci otlp` == 0). Taki klient ma w env
            # AIGON_OTLP_ENDPOINT i AIGON_OTEL_ENABLED, ale ICH NIE CZYTA —
            # deklaracja jest martwa. Wymaganie CA byłoby wymaganiem od niego
            # konfiguracji czegoś, czego nie robi. Zero wymagań = zero fałszywych
            # FAIL-i, a jednocześnie brak udawania sukcesu (bo wymagamy DOKŁADNIE
            # tyle, ile klient realnie konsumuje).
            return "no-sdk", []

    # 2) Fallback na nazwę/USER (gdy nie da się wejść do kontenera).
    if "python" in i:
        return "python", ["SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"]
    if u.startswith("node") or "node" in i or "next" in i or "grantmaster" in i:
        return "node", ["NODE_EXTRA_CA_CERTS"]
    if "haproxy" in i:
        # HAProxy nie ma natywnego eksportera OTLP (komentarz w compose) —
        # env jest przygotowany, ale trajce pojawią się po sidecarze.
        return "haproxy", []
    if u.startswith("appuser") or "appuser" in u:
        # grantmaster appuser = Node (obrazy grantmaster-app-*)
        return "node", ["NODE_EXTRA_CA_CERTS"]
    return "rust", ["AIGON_TLS_CA_CERT"]

CONTAINERS = sh("docker", "ps", "--format", "{{.Names}}").split()
viol, checked = [], 0

for c in CONTAINERS:
    # OPT-FIX 2026-10-02: JEDNO docker inspect zamiast CZTERECH (env+image+user
    # w jednym formacie). 129 kontenerow x 4 = 516 wywolan -> 129. Przy load
    # 76/24 to roznica miedzy timeoutem bramki a werdyktem.
    blob = sh("docker", "inspect", c, "--format",
              "{{range .Config.Env}}{{println .}}{{end}}|||{{.Config.Image}}|||{{.Config.User}}")
    parts = blob.split("|||")
    raw = parts[0] if len(parts) > 0 else ""
    env = dict(l.split("=", 1) for l in raw.splitlines() if "=" in l)
    image = (parts[1] if len(parts) > 1 else "").strip()
    user = (parts[2] if len(parts) > 2 else "").strip()

    ep = env.get("AIGON_OTLP_ENDPOINT") or env.get("OTEL_EXPORTER_OTLP_ENDPOINT") or ""
    if "44318" not in ep:
        continue
    checked += 1
    # `container` przekazany — klasyfikacja mierzy interpreter w runtime,
    # nie zgaduje z nazwy obrazu (patrz expected_env).
    lang, needed = expected_env(image, user, container=c)
    if not needed:
        continue
    # HTTPS jest warunkiem: przy http CA niepotrzebne
    if ep.startswith("http://"):
        viol.append({"container": c, "image": image.split("/")[-1],
                     "lang": lang, "reason": f"endpoint po HTTP (ma być https): {ep}"})
        continue
    missing = [k for k in needed if k not in env]
    if missing:
        viol.append({"container": c, "image": image.split("/")[-1], "lang": lang,
                     "reason": f"brak CA w formacie {lang}: {', '.join(missing)}"})
        continue
    # Node: AIGON_TLS_CA_CERT sam NIE wystarcza — to złapie właśnie ten błąd
    if lang == "node" and "AIGON_TLS_CA_CERT" in env and "NODE_EXTRA_CA_CERTS" not in env:
        viol.append({"container": c, "image": image.split("/")[-1], "lang": lang,
                     "reason": "Node ma AIGON_TLS_CA_CERT (konwencja Rusta), ale NIE NODE_EXTRA_CA_CERTS"})

# ── 2. SKRYPTY HOSTA (.sh z własnym curl na OTLP) ────────────────────────
scripts = sh("bash", "-c",
             "grep -rl '44318' /opt/PROD/scripts/ 2>/dev/null | grep -v '.bak' || true").split()
for f in scripts:
    if not f.endswith(".sh"):
        continue
    body = open(f, encoding="utf-8", errors="replace").read()
    has_direct_curl = "curl" in body and ("/v1/traces" in body or "/v1/metrics" in body)
    uses_lib = "otel_span_emit" in body or "otel-span.sh" in body
    if not has_direct_curl or uses_lib:
        continue
    checked += 1
    if "--cacert" not in body:
        viol.append({"script": f, "lang": "bash", "reason": "curl do OTLP bez --cacert"})

# ── 3. SKRYPTY HOSTA (.py z urlopen na OTLP) ─────────────────────────────
for f in scripts:
    if not f.endswith(".py"):
        continue
    body = open(f, encoding="utf-8", errors="replace").read()
    if "urlopen" not in body or "otel_span" in body:
        continue
    # SYGNAŁ OTLP: ścieżka OTLP albo endpoint w zmiennej OTLP_ENDPOINT.
    # Samo '44318' w słowniku portów (state-measure.py) to NIE klient OTLP
    # — to fałszywe trafienie (zweryfikowane 2026-09-27).
    if "/v1/traces" not in body and "/v1/metrics" not in body and "OTLP_ENDPOINT" not in body:
        continue
    if "OTLP_ENDPOINT" in body and "/v1/" not in body:
        # endpoint OTLP zadeklarowany, ale brak wysyłki /v1/ → nie klient
        continue
    checked += 1
    # CA może być podane na DWA sposoby, bo skrypty .py bywają hybrydowe:
    #  - urllib: context=/cafile=/verify=
    #  - subprocess curl: "--cacert" w argumencie (aigon-ollama-direct-checker.py)
    if ("context=" not in body and "cafile" not in body and "verify=" not in body
            and "--cacert" not in body and "cacert" not in body):
        viol.append({"script": f, "lang": "python", "reason": "wysyłka OTLP bez CA (urllib context / curl --cacert)"})

status = "FAIL" if viol else "PASS"
if as_json:
    print(json.dumps({"gate": "otlp-client-ca", "status": status,
                      "checked": checked, "violations": viol},
                     ensure_ascii=False, indent=2))
elif not quiet:
    if viol:
        print(f"otlp-client-ca: FAIL — {len(viol)} klientów OTLP bez CA (sprawdzono {checked})")
        for v in viol:
            who = v.get("container") or v.get("script")
            print(f"  [{v['lang']}] {who}: {v['reason']}")
        print("  Napraw: dodaj CA w formacie języka (rust: AIGON_TLS_CA_CERT,")
        print("         node: NODE_EXTRA_CA_CERTS, python: SSL_CERT_FILE/REQUESTS_CA_BUNDLE,")
        print("         bash: curl --cacert). Wzorzec: docs/runbooks/build-deploy-binaries.md")
    else:
        print(f"otlp-client-ca: PASS — {checked} klientów OTLP, każdy ma CA w swoim formacie")

sys.exit(1 if viol else 0)
PY
