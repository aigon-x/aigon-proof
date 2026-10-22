#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/cpu-tier.sh — gate cpu-tier (hook-runner)
#
#  BLIZNIACZKA gpu-one-model.sh po stronie CPU. Tamta pilnuje, by na GPU
#  stal JEDEN duzy model. Ta pilnuje, by na CPU NIE STAL ZADEN duzy.
#
#  KANON 2026-09-19 (Suweren): tier CPU/TINY nie moze trzymac modelu 30B.
#  Zmierzone: 17.7 GiB wag + 6.1 GiB KV w RAM hosta => 12-45 s na request,
#  HTTP 499, ~1 blad/s w petli. Problem WRACAL wielokrotnie, bo poprawki
#  ladowaly w ARTEFAKCIE zamiast w zrodle.
#
#  TRZY PLIKI, TRZY ROLE — mylenie ich bylo przyczyna nawrotow:
#    config/providers.yaml            = PUNKT PRAWDY (edytuj TUTAJ)
#    runtime/manifests/providers.yaml = artefakt L4 (generuje aigon-config.py
#                                       gen_providers; edycja NIE TRZYMA)
#    /etc/aigon/providers.yaml        = zywy plik montowany przez router
#
#  PULAPKA ZAPISANA W KODZIE: wzorzec "3b" bez granic tokenu trafia w "A3B"
#  wewnatrz "Huihui-Qwen3-Coder-30B-A3B" i przepuszcza model 30-miliardowy
#  jako maly. Detektor MUSI uzywac granic tokenu (zmierzone 2026-09-19).
#
#  CO SPRAWDZA (zywy stan, nie diff):
#    1. Zaden provider tieru CPU/TINY nie trzyma duzego modelu — w KAZDYM
#       z trzech plikow.
#    2. Punkt prawdy i artefakt L4 sie nie rozjechaly.
#    3. Straz aigon-ollama-cpu-guard odpowiada na :11435.
#    4. Backend CPU :11445 NIE jest osiagalny spoza petli zwrotnej.
#       (2026-09-19: nasluchiwal na 0.0.0.0 => kazdy wezel mesha mogl wejsc
#        Z POMINIECIEM strazy. Zmierzone HTTP 200 z tailnet.)
#
#  Exit 0 = PASS, 1 = FAIL.
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail
PROD="${PROD_ROOT:-/srv/aigon}"
FAIL=0
say() { printf '%s\n' "$*"; }

# ── 1+2. Modele w tierach CPU oraz dryf zrodlo↔artefakt ────────────────
python3 - "$PROD" <<'PY'
import sys, os, re, yaml
prod = sys.argv[1]
CPU_PROVIDERS = {"ollama-cpu", "ollama-tiny"}
# Granice tokenu SA KONIECZNE — patrz naglowek (pulapka "A3B" ~ "3b").
SMALL = re.compile(r'(?<![a-z0-9])(0\.5b|1\.5b|1b|3b)(?![a-z0-9])|embed|nomic|bge', re.I)

FILES = [
    ("zrodlo",   os.path.join(prod, "config/providers.yaml")),
    ("artefakt", os.path.join(prod, "runtime/manifests/providers.yaml")),
    ("zywy",     "/etc/aigon/providers.yaml"),
]

def cpu_models(path):
    """Zwraca [(provider, model, tag)] dla tierow CPU. None gdy pliku brak."""
    if not os.path.exists(path):
        return None
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    # Klucz kanoniczny to "entries". Pomylka z "providers" dawala ciche
    # 0 naruszen — falszywa zielen na pliku z modelem 30B (zmierzone).
    if isinstance(doc, list):
        entries = doc
    else:
        entries = doc.get("entries") or doc.get("providers") or []
    out = []
    for e in entries:
        if not isinstance(e, dict):
            continue
        if e.get("provider") in CPU_PROVIDERS:
            out.append((e.get("provider"), str(e.get("model", "")), e.get("model_tag")))
    return out

bad = 0
seen = {}
for role, path in FILES:
    rows = cpu_models(path)
    if rows is None:
        print(f"  UWAGA {role}: brak pliku {path} (pomijam)")
        continue
    seen[role] = sorted((p, m) for p, m, _ in rows)
    for prov, model, tag in rows:
        if not SMALL.search(model):
            print(f"  FAIL {role}: {prov} trzyma ZA DUZY model '{model}' ({path})")
            bad += 1
        if tag and tag != "cpu":
            print(f"  FAIL {role}: {prov} ma model_tag='{tag}', oczekiwane 'cpu' ({path})")
            bad += 1

if "zrodlo" in seen and "artefakt" in seen and seen["zrodlo"] != seen["artefakt"]:
    print("  FAIL dryf: punkt prawdy i artefakt L4 sie rozjechaly")
    print(f"         zrodlo  : {seen['zrodlo']}")
    print(f"         artefakt: {seen['artefakt']}")
    print("         napraw: aigon-config.py generate providers --apply")
    bad += 1

# Zywy plik routera ma WLASNY, wezszy zestaw providerow — brak wpisu
# (np. ollama-tiny) to NIE jest sprzecznosc, tylko inny zakres. Porownujemy
# wylacznie czesc wspolna; inaczej bramka krzyczy na poprawny stan.
if "zrodlo" in seen and "zywy" in seen:
    src = dict(seen["zrodlo"])
    live = dict(seen["zywy"])
    wspolne = set(src) & set(live)
    rozjazd = [(k, src[k], live[k]) for k in sorted(wspolne) if src[k] != live[k]]
    for prov, a, b in rozjazd:
        print(f"  FAIL dryf zywy: {prov} zrodlo='{a}' vs /etc/aigon='{b}'")
        bad += 1
    brak = sorted(set(src) - set(live))
    if brak:
        print(f"  UWAGA: /etc/aigon nie definiuje {brak} (wezszy zakres, nie blad)")

if bad == 0:
    print("  OK: tiery CPU trzymaja wylacznie male modele, pliki zgodne")
sys.exit(1 if bad else 0)
PY
[ $? -ne 0 ] && FAIL=1

# ── 3. Straz na :11435 ─────────────────────────────────────────────────
if curl -s -o /dev/null --max-time 8 http://127.0.0.1:11435/api/tags 2>/dev/null; then
  say "  OK: straz CPU odpowiada na :11435"
else
  say "  FAIL: straz CPU (:11435) nie odpowiada — tier CPU bez ochrony"
  FAIL=1
fi

# ── 4. Backend :11445 NIE moze byc osiagalny spoza petli zwrotnej ──────
LISTEN=$(ss -lnt 2>/dev/null | awk '$4 ~ /:11445$/ {print $4}')
if [ -z "$LISTEN" ]; then
  say "  UWAGA: nikt nie nasluchuje na :11445 (backend CPU nie stoi?)"
elif printf '%s' "$LISTEN" | grep -qv '^127\.0\.0\.1:'; then
  say "  FAIL: backend CPU nasluchuje na '$LISTEN' zamiast 127.0.0.1:11445"
  say "        => kazdy wezel mesha moze wejsc Z POMINIECIEM strazy"
  say "        napraw: OLLAMA_HOST=127.0.0.1:11445 w drop-inie ollama-cpu.service"
  FAIL=1
else
  say "  OK: backend CPU tylko na petli zwrotnej ($LISTEN)"
fi

if [ "$FAIL" -eq 0 ]; then
  say "cpu-tier: PASS"
else
  say "cpu-tier: FAIL — tier CPU moze przyjac model, ktorego nie uciagnie"
fi
exit "$FAIL"
