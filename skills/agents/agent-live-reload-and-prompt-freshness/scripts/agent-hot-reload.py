#!/usr/bin/env python3
"""
agent-hot-reload.py — HOT RELOAD promptów i konfiguracji WSZYSTKICH agentów.

Wzorzec: plik-znacznik + unieważnienie cache + wymuszony sync, wołany z crona
co minutę. NIE zabija procesu — nowe sesje czytają świeży stan. Cichy, gdy brak
zmian (wzorzec watchdoga). Nigdy nie wywala crona wyjątkiem.

ZMIERZONY DEFEKT KTÓRY TO DOMYKA:
  Zmiana promptu NIE wchodziła bez ręcznego restartu:
    - `hermes config reload`      -> NIE ISTNIEJE
    - handler SIGHUP w gateway    -> NIE ISTNIEJE (tylko log w shutdown_forensics)
    - sync-agent-models.py:3457   -> "Nie restartuje serwisu przy kazdym syncu"
    - gateway._agent_cache        -> trzyma ZAMROŻONY `_cached_system_prompt`
  Objaw: poprawka w prompt_builder.py była w pliku i test na świeżym procesie
  dawał -60%, a żywa delegacja wysyłała dalej 40k tokenów -> HTTP 413.

Trzy warstwy detekcji (sygnatura = sha256 z (path, mtime_ns, size),
spójnie z _build_skills_manifest w prompt_builder.py — nie wymyślam nowego):
  W1_FILES   — dane promptu (config, tożsamości, pamięć, snapshot) -> unieważnij cache
  W1_CODE    — kod rdzenia -> zmiana WYMAGA RESTARTU (raportuj wprost!)
  W1_PLUGINS — hooki (transform_llm_output) nie wchodzą w żywą sesję
  W2_SSOT    — config/agent-models.yaml -> wymuś sync-agent-models.py natychmiast

UŻYCIE:
  agent-hot-reload.py --watch    # pętla (cron co min) — wykryj i przeładuj
  agent-hot-reload.py --force    # wymuś teraz (bez wykrywania)
  agent-hot-reload.py --status   # co jest nieaktualne

DOSTOSUJ: ścieżki W1_FILES do realnego układu na hoście (sprawdź `ls`,
NIE zgaduj). Poniżej układ zmierzony na local-aigon 2026-10-01.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERMES = Path.home() / ".hermes"
STATE = HERMES / "state"
MARKER = STATE / "agent-hot-reload"
SNAP = STATE / "agent-hot-reload.sha"
LOG = Path("/var/log/aigon/agent-hot-reload.log")

# ── Dane promptu (W1) + RODZINA 7 AGENTÓW: qwen/claude/hermes/grok/codex/dsh/aigon-code ──
W1_FILES = [
    # Hermes (rdzeń)
    HERMES / "config.yaml",
    HERMES / "AGENTS.md",
    HERMES / ".skills_prompt_snapshot.json",   # UWAGA: w ~/.hermes/, NIE w skills/
    HERMES / "memories" / "MEMORY.md",
    HERMES / "memories" / "USER.md",
    # SSOT wspólny
    Path("/srv/aigon/config/agent-identity.md"),
    Path("/srv/aigon/config/agent-models.yaml"),
    Path("/srv/aigon/AGENTS.md"),
    # Rodzina: tożsamości per agent
    HERMES.parent / ".qwen" / "AGENTS.md",
    HERMES.parent / ".claude" / "AGENTS.md",
    HERMES.parent / ".claude" / "AIGON-AGENT-RULES.md",
    HERMES.parent / ".grok" / "AGENTS.md",
    HERMES.parent / ".codex" / "AGENTS.md",
    HERMES.parent / ".dsh" / "AGENTS.md",
    HERMES.parent / ".aigon" / "AGENTS.md",
    # Rodzina: konfigi per agent
    HERMES.parent / ".qwen" / "settings.json",
    HERMES.parent / ".grok" / "config.toml",
    HERMES.parent / ".aigon" / "profiles.json",
]
# Kod rdzenia: zmiana = nowy KOD, nie dane. WYMAGA restartu procesu.
W1_CODE = [
    HERMES / "hermes-agent" / "agent" / "prompt_builder.py",
    HERMES / "hermes-agent" / "agent" / "system_prompt.py",
    HERMES / "hermes-agent" / "agent" / "agent_init.py",
]
# Pluginy: hooki (transform_llm_output) nie wchodzą w żywą sesję.
W1_PLUGINS = [HERMES / "plugins"]
# SSOT wymagający natychmiastowego syncu (zamiast okna 15 min).
W2_SSOT = Path("/srv/aigon/config/agent-models.yaml")


def log(msg: str) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(timezone.utc).isoformat()
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(f"{ts} {msg}\n")
    except Exception:
        pass


def _hash_dir(d: Path) -> str:
    """Sygnatura katalogu (rekurencyjnie) — dla ~/.hermes/plugins."""
    h = hashlib.sha256()
    if not d.exists():
        return h.hexdigest()
    for p in sorted(d.rglob("*"), key=lambda x: str(x)):
        if p.is_file():
            try:
                st = p.stat()
                h.update(f"{p}|{st.st_mtime_ns}|{st.st_size}".encode())
            except OSError:
                pass
    return h.hexdigest()


def sig(paths: list[Path]) -> str:
    """sha256 z (ścieżka, mtime_ns, size) — jak _build_skills_manifest."""
    h = hashlib.sha256()
    for p in sorted(paths, key=lambda x: str(x)):
        try:
            st = p.stat()
            h.update(f"{p}|{st.st_mtime_ns}|{st.st_size}".encode())
        except OSError:
            h.update(f"{p}|MISSING".encode())
    return h.hexdigest()


def read_snap() -> dict:
    try:
        return json.loads(SNAP.read_text(encoding="utf-8"))
    except Exception:
        return {}


def write_snap(d: dict) -> None:
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        SNAP.write_text(json.dumps(d, indent=1), encoding="utf-8")
    except Exception as e:
        log(f"BLAD zapisu snapshotu: {e}")


def invalidate_prompt_caches() -> list[str]:
    """Unieważnij to, co da się BEZ restartu procesu. Zwraca WYKONANE akcje (dowód)."""
    done = []
    snap = HERMES / ".skills_prompt_snapshot.json"
    if snap.exists():
        try:
            backup = STATE / f"skills-snapshot.{int(time.time())}.bak"
            backup.write_bytes(snap.read_bytes())
            snap.unlink()
            done.append(f"usuniety snapshot skilli (kopia: {backup.name})")
        except Exception as e:
            done.append(f"BLAD usuniecia snapshotu: {e}")
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        MARKER.write_text(datetime.now(timezone.utc).isoformat(), encoding="utf-8")
        done.append(f"znacznik {MARKER.name} odswiezony")
    except Exception as e:
        done.append(f"BLAD znacznika: {e}")
    return done


def force_sync() -> str:
    script = Path("/srv/aigon/scripts/sync-agent-models.py")
    if not script.exists():
        return f"BRAK {script} — sync niemozliwy"
    try:
        r = subprocess.run([sys.executable, str(script)],
                           capture_output=True, text=True, timeout=180, cwd="/srv/aigon")
        return "sync-agent-models: OK" if r.returncode == 0 else \
               f"sync-agent-models: rc={r.returncode} {(r.stderr or '')[:150]}"
    except subprocess.TimeoutExpired:
        return "sync-agent-models: TIMEOUT 180s"
    except Exception as e:
        return f"sync-agent-models: BLAD {type(e).__name__}: {e}"


def gateway_pid() -> str:
    try:
        r = subprocess.run(["pgrep", "-f", "hermes_cli.main gateway run"],
                           capture_output=True, text=True)
        return r.stdout.strip().split("\n")[0] if r.stdout.strip() else ""
    except Exception:
        return ""


def run(force: bool = False, status_only: bool = False) -> int:
    snap = read_snap()
    s_data, s_code = sig(W1_FILES), sig(W1_CODE)
    s_plug, s_ssot = _hash_dir(W1_PLUGINS[0]), sig([W2_SSOT])
    d_data, d_code = snap.get("data"), snap.get("code")
    d_plug, d_ssot = snap.get("plugins"), snap.get("ssot")

    ch_data = force or (d_data is not None and d_data != s_data)
    ch_code = d_code is not None and d_code != s_code
    ch_plug = d_plug is not None and d_plug != s_plug
    ch_ssot = force or (d_ssot is not None and d_ssot != s_ssot)
    first = d_data is None

    if status_only:
        print(f"gateway pid: {gateway_pid() or 'BRAK'}")
        print(f"dane promptu zmienione:   {ch_data}")
        print(f"kod rdzenia zmieniony:    {ch_code}")
        print(f"pluginy zmienione:        {ch_plug}")
        print(f"SSOT zmieniony:           {ch_ssot}")
        if ch_code:
            print("  UWAGA: zmiana KODU rdzenia — potrzebny restart gateway")
            print("         (prompt w pamieci procesu; hot reload dotyczy danych)")
        return 0

    if first:
        write_snap({"data": s_data, "code": s_code, "plugins": s_plug,
                    "ssot": s_ssot, "ts": datetime.now(timezone.utc).isoformat()})
        log("baseline ustanowiony (pierwszy przebieg — cicho)")
        return 0

    if not (ch_data or ch_ssot or ch_code or ch_plug):
        return 0  # nic się nie zmieniło — cisza

    actions = []
    if ch_ssot:
        actions.append(force_sync())
    if ch_data:
        actions.extend(invalidate_prompt_caches())
    if ch_plug:
        actions.append("PLUGINY zmienione — hooki (transform_llm_output) NIE wchodza "
                       "w zywa sesje; nowa sesja albo restart gateway")
    if ch_code:
        actions.append("KOD RDZENIA zmieniony — hot reload danych NIE wystarczy; "
                       f"wymagany restart gateway (pid {gateway_pid() or '?'})")

    write_snap({"data": s_data, "code": s_code, "plugins": s_plug,
                "ssot": s_ssot, "ts": datetime.now(timezone.utc).isoformat()})
    log("HOT RELOAD: " + " | ".join(actions))
    print("HOT RELOAD wykonany:")
    for a in actions:
        print(f"  - {a}")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if "--status" in args:
        return run(status_only=True)
    if "--force" in args:
        return run(force=True)
    return run()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log(f"BLAD KRYTYCZNY: {type(e).__name__}: {e}")
        sys.exit(0)  # watchdog nigdy nie wywala crona
