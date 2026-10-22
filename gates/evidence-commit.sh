#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  tools/gates/evidence-commit.sh — gate evidence-commit (hook-runner)
#
#  Wydzielony z case'a hook-runner.sh (digital twin 2026-09-05).
#  Post-commit: zapisuje SHA commita jako dowód — zawsze PASS (informacyjny).
#
#  Kontrakt: exit 0 = PASS (zawsze — gate rejestruje sha, nie blokuje).
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SHA=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")
echo "evidence-commit: PASS (commit=$SHA)"
exit 0
