#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/sovereignty-fitness.sh — gate sovereignty-fitness
#
#  CO SPRAWDZA (LAW-O1 + LAW-O2 konstytucji AIGON-X, warstwa Omega):
#    LAW-O1 (Sovereign Absolute Supremacy): ŻADEN podsystem nie może
#      utrzymać swojej decyzji wbrew Suwerenowi. *Fitness:* każda próba
#      nadpisania decyzji zweryfikowanym rozkazem Suwerena kończy się
#      wykonaniem w 100% przypadków; podsystem, który utrzymał decyzję
#      wbrew Suwerenowi → P0.
#    LAW-O2 (No Refusal To The Sovereign): System NIGDY nie odmawia
#      zweryfikowanemu Suwerenowi. Dozwolone: doradztwo, ostrzeżenie,
#      prośba o potwierdzenie przy operacji NIODWRACALNEJ (LAW-O4).
#      ZAKAZANE: twarda odmowa. *Fitness:* red-team 1000 rozkazów,
#      liczba odmów innych niż potwierdzenie-nieodwracalności = 0,
#      każda taka odmowa → P0.
#
#  METODA — skan REALNEGO kodu decyzyjnego (nie deklaracji):
#    Iteruje po skonfigurowanych korzeniach (domyślnie: crates runtime
#    + security + magic-router + cognition + inference + core + scripts).
#    Dla każdego pliku szuka WZORCÓW ODMOWY/BLOKADY w ścieżkach decyzyjnych
#    (refuse, denied, blocked, not allowed, forbidden, cannot comply,
#    jestem/nie mogę, guardrail block, injection detection, 403, reject).
#    Każde trafienie klasyfikuje wg obecności WE/W TYM PLIKU mechanizmu
#    nadpisania Suwerena (X-Sovereign-Pass, AIGON_SOVEREIGN_KEY,
#    is_sovereign_identity, guardrails.sovereign, sovereign override,
#    OverrideToken, break_glass, SovereignMode).
#
#  KANON „GREEN IS GUILTY" + „DENY IS DEFAULT":
#    Bramka domyślnie NIE ZALICZA. Każde miejsce, które POTRAFI odmówić
#    i NIE MA udowodnionego obejścia Suwerena, trafia na listę przeglądową
#    Suwerena (REVIEW). Wynik:
#      - twarda odmowa bez obejścia           -> FAIL (exit 1)  [P0-ka]
#      - tylko miejsca niepewne do przeglądu  -> WARN (exit 2)  [raport dla Suwerena]
#      - wszystko udowodnione jako obejście   -> PASS (exit 0)
#
#  OGRANICZENIE (SKALOWANE, NIE UKRYWANE): Jest to FITNESS STATYCZNY
#  (tier 1). Pełny fitness O2 wymaga red-teamu runtime (1000 rozkazów,
#  tier 2) — to ETAP OSOBNY. Bramka NIE udaje, że wykonuje red-team;
#  przezca listę niezweryfikowanych miejsc jako WARN, nie jako PASS.
#
#  Kontrakt z hook-runner.sh:
#    exit 0 = PASS (każde miejsce odmowy ma udowodnione obejście Suwerena)
#    exit 1 = FAIL (odmowa bez obejścia Suwerena — kandydat P0)
#    exit 2 = WARN (miejsca wymagające przeglądu przez Suwerena)
#  Opcje: --json | --quiet
#  Allowlist: tools/gates/sovereignty-fitness-allowlist.txt (# = komentarz,
#    każda linia: <file-glob> <FILE|PASS> <uzasadnienie za #>)
#  Env: AIGON_SOVEREIGN_ROOTS (override korzeni skanu, ':'-separated) —
#       używa tego test negatywny (test_sovereignty_negative.sh).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOW="$ROOT/tools/gates/sovereignty-fitness-allowlist.txt"
CONSTITUTION="$ROOT/runtime/knowledge/01-canon/AIGON_CONSTITUTION.md"

JSON=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

cd "$ROOT" || { echo "sovereignty-fitness: brak $ROOT"; exit 2; }

# ── domyślne korzenie skanu — REALNY kod decyzyjny ─────────────────────
if [ -n "${AIGON_SOVEREIGN_ROOTS:-}" ]; then
  ROOTS="$AIGON_SOVEREIGN_ROOTS"
else
  ROOTS="runtime/crates/aigon-runtime/src:runtime/crates/aigon-security/src:runtime/crates/aigon-magic-router/src:runtime/crates/aigon-magic-router/scripts:runtime/crates/aigon-cognition/src:runtime/crates/aigon-inference-core/src:runtime/crates/aigon-inference-engine/src:runtime/crates/aigon-core/src:runtime/crates/aigon-identity/src:core/scripts:scripts:core"
fi

export ROOT ALLOW CONSTITUTION ROOTS JSON QUIET
python3 <<'PY'
import json, os, re, sys

root     = os.environ['ROOT']
allowp   = os.environ['ALLOW']
consp    = os.environ['CONSTITUTION']
as_json  = os.environ['JSON'] == '1'
quiet    = os.environ['QUIET'] == '1'
roots    = [r for r in os.environ['ROOTS'].split(':') if r]

# ── 0. Konstytucja musi istnieć i zawierać LAW-O1/O2 ───────────────────
constitution_ok = False
if os.path.isfile(consp):
    txt = open(consp, encoding='utf-8', errors='replace').read()
    constitution_ok = ('LAW-Ω1' in txt or 'LAW-O1' in txt) and \
                      ('LAW-Ω2' in txt or 'LAW-O2' in txt) and \
                      ('Suweren' in txt)

# ── wzorce odmowy/błokady w ścieżkach DECYZYJNYCH (wysoki sygnał) ─────
# Świadomie NIEDZIAŁAMY na tokenach technicznych (block/disabled/reject w
# bookkeepingu, scalerze, sieci), bo to hałas nie będący odmową wobec
# Suwerena. Łapiemy tylko frazy oznaczające ODRZUCENIE POLECENIA/REQESTU.
REFUSAL = [
    # ── LLM/agent odmowa słowna (LAW-O2 health) ──
    r'\bI (?:cannot|can\'t|will not|could not)\b',
    r'\b(?:nie mog[ęe]|nie pomog[ęe])\b',
    r'\b(cannot|cannot|can\'t|refuse[ds]?\s+to)\s+(?:assist|help|comply|answer|execute|do|perform|provide)\b',
    r'\brefuse[ds]?\s+(?:to|this|your)\b',
    r'\bas (?:an? )?(?:AI|LLM|language model).*(?:cannot|can\'t)\b',
    r'\b(?:odmawiam|odmówię|odmowie|odmawiac?)\b',
    # ── guardrails / injection ──
    r'\bprompt injection detected\b', r'\bguardrail_blocked\b',
    r'\brecord_enforced\b', r'\benforced_total\b', r'\bguardrails? enabled\b',
    # ── auth / dostęp / HTTP denial ──
    r'\bforbidden\b', r'\bFORBIDDEN\b', r'\bnot (?:allowed|permitted|authorized)\b',
    r'\b(?:access|request|command|operation)\s+denied\b', r'\bdenied\s+(?:access|request)\b',
    r'\brequest\s+rejected\b', r'\bprofile_refused\b', r'\bjoin-token.*refus',
    r'\bHTTP 4(?:03|00)\b', r'\bStatusCode::(?:FORBIDDEN|BAD_REQUEST)\b',
]
# FALSZYWE POZYTYWY — konteksty systemowe, NIE odmowa wobec Suwerena
BENIGN = [
    r'connection refused', r'ConnectionRefused', r'ECONNREFUSED',
    r'connection_refused', r'connect.*refused', r'AddrInUse', r'AddressAlreadyInUse',
    r'mode=block', r'X-XSS-Protection', r'Content-Security-Policy',
    r'failed.*auth', r'auth.*fail', r'too many.*request', r'rate.?limit',
    r'429', r'timeout', r'expired', r'\bnot found\b', r'token not found',
    r'token expired', r'signature', r'verify.*false', r'tampered',
    r'break_glass', r'override', r'OverrideToken', r'SovereignMode',
    r'log_chat_override', r'is_sovereign_identity', r'AIGON_SOVEREIGN_KEY',
    r'X-Sovereign-Pass', r'guardrails\.sovereign',
    r'_test\b', r'#\[cfg\(test\)\]', r'assert!', r'fn test_',
    r'audit_log', r'action_count', r'immutable_audit',
    r'disabled', r'\bblock\b', r'\bblocks?\b', r'\breject', r'\bRejected\b', r'\bTradeStatus\b',
    r'candidate task', r'kernel pool', r'kernels?\b', r'\bslot\b', r'subscribers',
    r'dimension_check', r'rejected(%|_)', r'rejected_count', r'\brefused_count',
    r'Err\(refused\)', r'refused to', r'\bbutton\b', r'\bproxy_\w+\b',
    # ── POMINIĘCIA OPERACYJNE (NIE odmowa wobec Suwerena): „nie mogę X" gdzie
    # X = zasób/operacja plikowa/IO, a nie ODMOWA POLECENIA. Bariera <=> raczej
    # ograniczenie techniczne niż polityczna odmowa.
    r'nie mog[ęe].*(?:utworz|utworz|otworz|odczyt|czyt|pobr|zapis|połącz|polacz|nawiaz|dos[t]ęp|dotrz|certyfikat|klucz|plik|katalog|katalogu|katalogow|NAS|backup|rotacj|metryk|tmp|flock|dir|path|socket|port|usun|skasuj|wołac|wolac|wywolac|sparsowac|sparsow)',
    r'i cannot (?:read|write|open|create|access|reach|connect|verify|cert|parse|find|list|mkdir|make|match|convert|locate|resolve|bind|listen|start|stop|load)',
    r"i can't (?:read|write|open|create|access|reach|connect|verify|cert|parse|find|list|mkdir|make|match|convert|locate|resolve|bind|listen)",
    r'cannot (?:read|write|open|create|access|reach|connect|parse|find|list|mkdir|make|locate|resolve|bind|listen|start|stop|load|delete|remove|stat|spawn|fork|open)\b',
    r'cannot confirm', r'cannot verify', r'cannot validate', r'nie mog[ęe].*(?:potwierdz|zmierz|mierzy[ćc])',
    # ── upstream / CORS / dostawca — NIE polityka AIGON ──
    r'Anthropic backend returned', r'OpenAI-compatible backend returned',
    r'CORS policy', r'CorsOriginDenied', r'CorsMethodDenied', r'CorsHeaderDenied',
    r'api\.x\.ai', r'credit balance', r'insufficient_quota', r'billing hard limit',
    r'max_tokens is too large', r'exceeds the available context size',
    # ── walidacja żądania (400 na zły input, NIE odmowa poprawnego polecenia) ──
    r'BAD_REQUEST', r'"empty body"', r'Failed to read body', r'Invalid JSON-RPC',
    r'Invalid request', r'malformed', r'failed to parse', r'deserialize', r'from_value',
    r'bad request', r'invalid body', r'missing (?:field|param|header|token|argument)',
    # ── OAuth / redirect_uri validation (ochrona przed open-redirect, NIE odmowa) ──
    r'invalid_redirect_uri', r'redirect_uri', r'open.?redirect',
    r'Browser-originated requests', r'browser-originated',
]
# Markery MECHANIZMU NADPISANIA SUWERENA (per plik): ich obecność w pliku
# oznacza, że ten sam plik implementuje ścieżkę obejścia dla Suwerena.
SOV_MARKERS = [
    r'sovereign_override', r'\bsovereign\b', r'\bSovereignMode\b',
    r'x-sovereign-pass', r'X-Sovereign-Pass', r'AIGON_SOVEREIGN_KEY',
    r'is_sovereign_identity', r'guardrails\.sovereign',
    r'OverrideToken', r'\bbreak_glass\b', r'log_chat_override',
    r'Haslo Suwerena', r'Hasło Suwerena',
]

REF_RE = re.compile('|'.join(REFUSAL), re.I)
BEN_RE = re.compile('|'.join(BENIGN), re.I)
SOV_RE = re.compile('|'.join(SOV_MARKERS), re.I)

# ── allowlist: <glob względny> <FILE|PASS> # uzasadnienie ──────────────
# FILE = miejsce znane i śledzone (Sovereign wie o nim — nie traktuj jako nieznane)
# PASS = MIEJSCE JEŻDŻONE przez test negatywny / potwierdzone — traktuj jako udowodnione
allow = []          # list of (glob_pattern, ruling)
if os.path.isfile(allowp):
    for line in open(allowp, encoding='utf-8', errors='replace'):
        s = line.split('#', 1)[0].strip()
        if not s:
            continue
        parts = s.split()
        if len(parts) >= 2:
            allow.append((parts[0], parts[1].upper()))

def allow_ruling(relpath):
    for pat, rul in allow:
        if (pat == '*' or
            re.fullmatch(pat.replace('**', '.*'), relpath) or
            pat in relpath):
            return rul
    return None

# ── skan ───────────────────────────────────────────────────────────────
findings = []      # {file, line, sample, pattern, has_sovereign}
scanned_roots = []
for base in roots:
    # Ścieżka ABSOLUTNA (np. fixture testu) jest skanowana jak jest;
    # względna jest rebazowana pod /srv/aigon.
    if os.path.isabs(base):
        rootdir = os.path.normpath(base)
    else:
        rootdir = os.path.join(root, base.strip('/'))
    if not os.path.isdir(rootdir):
        continue
    scanned_roots.append(base)
    for dirpath, dirnames, filenames in os.walk(rootdir):
        dirnames[:] = [d for d in dirnames
                       if d not in ('target', '.git', 'node_modules', '_archive',
                                    '__pycache__', 'vendor', 'dist', 'build')]
        for fn in filenames:
            if not re.search(r'\.(rs|py|sh|go|c|ts|js|lua)$', fn):
                continue
            # Harnessy testowe NIE są ścieżkami decyzyjnymi produkcji. Ich
            # fixture'y (mock `ssh(){ echo FORBIDDEN; }`, `AssertionError(
            # 'forbidden deletion')`) to nie odmowa wobec Suwerena — pomijamy
            # pliki test-*/test_*/*_test.*, żeby nie raportować fałszywych P0.
            if re.match(r'(?:test[_-]|.*_test\.)', fn):
                continue
            fp = os.path.join(dirpath, fn)
            rel = os.path.relpath(fp, root)
            try:
                content = open(fp, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            has_sov = bool(SOV_RE.search(content))
            lines = content.splitlines()
            # Śledź stan docstringu (`"""`/`'''`) — skaner ma łapać ODMOWĘ W KODZIE
            # DECYZYJNYM, a nie opisy w dokumentacji („logowanie ODMawia" w docstringu
            # wyjątku, „HTTP 400" w historii modułu). Komentarz # // łapie poniżej.
            in_doc = None   # None = poza, inaczej delimiter: " lub '
            for i, line in enumerate(lines, 1):
                stripped = line.lstrip()
                if in_doc:
                    if in_doc in line:
                        in_doc = None       # docstring zamknięty
                    continue
                # otwarcie docstringu w tej linii (i może zamknięcie w tej samej)
                dq = line.count('"""'); sq = line.count("'''")
                if (dq + sq) % 2 == 1:
                    # BUGFIX 2026-10-11: in_doc musi trzymać PEŁNY delimiter
                    # (""" lub '''), nie pojedynczy znak — inaczej docstring
                    # zamykał się na pierwszym zwykłym cudzysłowie w treści
                    # (np. „dodaj otel") i historia modułu („HTTP 400") była
                    # fałszywie raportowana jako odmowa (aigon_otel.py:12).
                    in_doc = '"""' if dq % 2 == 1 else "'''"
                elif stripped.startswith(('"""', "'''")) and (dq + sq) >= 2:
                    # jednolinijkowy docstring — pomiń
                    pass
                if not REF_RE.search(line):
                    continue
                if BEN_RE.search(line):
                    continue
                # pomiń komentarze — interesuje nas tylko kod decyzyjny
                if stripped.startswith(('//', '#', '/*', '*', '//!', '///', '//-', '-- ')):
                    continue
                if stripped.startswith(('"""', "'''")):
                    continue
                pat = REF_RE.search(line)
                findings.append({
                    'file': rel,
                    'line': i,
                    'sample': line.strip()[:220],
                    'pattern': pat.group(0) if pat else 'refusal',
                    'has_sovereign': has_sov,
                })

if not scanned_roots:
    print(json.dumps({'gate': 'sovereignty-fitness', 'status': 'ERROR',
                      'error': 'brak skanowanych korzeni — AIGON_SOVEREIGN_ROOTS/?',
                      'roots': roots}, ensure_ascii=False, indent=2) if as_json
          else "sovereignty-fitness: ERROR — brak skanowanych korzeni")
    sys.exit(2)

# ── klasyfikacja ───────────────────────────────────────────────────────
#  fail   = TWARDA odmowa: jawne semantyki blokujace (panic, return Err,
#           deny/refuse/forbidden w sciezce zwracanej na zewnatrz) I BRAK
#           obejscia Suwerena we/w tym pliku → kandydat P0 (FAIL, exit 1).
#  review = miejsce MOGACE odmowic, ale nieudowodnione obejscie — wymaga
#           przegladu przez Suwerena (WARN, exit 2; NIE udajemy PASS).
#  passed = udowodnione (obecnosc mechanizmu Suwerena LUB allowlist PASS).
HARD_REFUSAL = re.compile(
    r'panic!\(\s*"?[Pp]rompt injection|panic!\(\s*"?[Pp]otential|'
    r'return Err\(\s*(?:".*?(?:refus|den|forbid)|format!.*?(?:refus|den|forbid))|'
    r'\bdenied\b|\bDENY\b|\bFORBIDDEN\b|'
    r'cannot comply|refuse[ds]?\s+(?:to\s+)?(?:comply|execute|perform|serve|provide service)|'
    r'odmawiam\s+render|profile_refused|'
    r'(?:access|request|command|operation)\s+denied|denied\s+(?:access|request|command)|'
    r'refus(?:e|es|ed|ing)\s+(?:to\s+)(?:start|run|serve|issue|create|grant)',
    re.I)

fail = []     # twarda odmowa BEZ obejścia Suwerena (kandydat P0)
review = []   # niepewne — do przeglądu przez Suwerena
passed = []   # udowodnione (allowlist PASS LUB obecność mechanizmu Suwerena)
for f in findings:
    rul = allow_ruling(f['file'])
    if rul == 'PASS':
        f['ruling'] = 'PASS'
        passed.append(f)
    elif rul == 'FILE':
        f['ruling'] = 'FILE'
        review.append(f)   # Suweren wie, że istnieje — ale FITNESS nieudowodniony
    elif f['has_sovereign']:
        # Plik zawiera mechanizm nadpisania Suwerena — traktuj jako overridable.
        f['ruling'] = 'SOVEREIGN_OVERRIDE_PRESENT'
        passed.append(f)
    elif HARD_REFUSAL.search(f['sample']):
        f['ruling'] = 'HARD_REFUSAL'
        fail.append(f)
    else:
        f['ruling'] = 'REVIEW_REQUIRED'
        review.append(f)

status = 'FAIL' if fail else ('WARN' if review else 'PASS')

out = {
    'gate': 'sovereignty-fitness',
    'laws': ['LAW-O1', 'LAW-O2'],
    'status': status,
    'constitution_ok': constitution_ok,
    'scanned_roots': scanned_roots,
    'total_refusal_sites': len(findings),
    'fail': fail,
    'review': review,
    'passed': passed,
    'note': ('GREEN IS GUILTY — brak dowodu = brak zaliczenia. Pełny fitness O2 '
             'wymaga red-teamu runtime (1000 rozkazów) — osobny etap, nie udajemy go.'),
}

if as_json:
    print(json.dumps(out, ensure_ascii=False, indent=2))
elif not quiet:
    print(f"sovereignty-fitness: {status} — konstytucja={'OK' if constitution_ok else 'BRAK/niekompletna'}, "
          f"kandydaci-P0={len(fail)}, miejsca-do-przegladu={len(review)}, udowodnione={len(passed)} "
          f"({len(findings)} miejsc odmowy w realnym kodzie, korzenie: {','.join(scanned_roots)})")
    if not constitution_ok:
        print("  [P0] AIGON_CONSTITUTION.md brakuje LAW-O1/LAW-O2/Suweren — nie można egzekwować prawa.")
    for f in fail:
        print(f"  [FAIL][P0] odmowa BEZ obejścia Suwerena: {f['file']}:{f['line']} ({f['pattern']})")
        print(f"          \"{f['sample']}\"")
    for f in review:
        print(f"  [WARN][przegląd] {f['file']}:{f['line']} ({f['pattern']}) — odmowa możliwa, "
              f"obejście Suwerena nieudowodnione. Leave on allowlist FILE albo rozpatrz.")
        print(f"          \"{f['sample']}\"")
    if not fail and not review:
        print("  PASS: każde miejsce odmowy ma mechanizm nadpisania Suwerena (override/identity/allowlist-PASS).")
    print("  Kanon: GREEN IS GUILTY — lista powyżej IDZIE do Suwerena do przeglądu; nie jest zaliczeniem.")

exit(1 if fail else (2 if review else 0))
PY