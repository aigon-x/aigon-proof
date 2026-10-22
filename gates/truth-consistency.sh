#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  tools/gates/truth-consistency.sh — adapter GATE-230 (hook-runner / os A)
#
#  WYGENEROWANY przez tools/gates/reconcile-gate-wiring.sh — NIE edytuj ręcznie.
#  Źródła: config/canonical/gate-registry.yaml (GATE-230, profil: PRE_PUSH)
#          config/canonical/hooks.yaml (trigger: git:pre-push + cyclic:6h)
#
#  Cienki ADAPTER, zero duplikacji logiki: hook-runner.sh uruchamia bramki
#  WYŁĄCZNIE jako tools/gates/<id>.sh, a kanoniczna implementacja żyje w
#  tools/verify/gates/domains/truth-consistency.sh. Ten plik przekazuje
#  sterowanie do kanonicznego źródła, więc istnieje JEDNA implementacja.
#
#  ROZKAZ SUWERENA 2026-10-14/15: obowiązkowa bramka na koniec CI/CD/deploy/
#  commita — sprawdza, czy po zmianach nie zostały rzeczy twierdzące nieprawdę
#  (dokumentacja/repo vs żywa rzeczywistość).
# ════════════════════════════════════════════════════════════════════════════
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$ROOT/tools/verify/gates/domains/truth-consistency.sh" "$@"
