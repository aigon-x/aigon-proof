---
name: capability-wiring-truth-audit
description: >-
  Audyt "REAL-executed vs static/aspirational" dla capability, pipeline'ów i
  wiedzy w <workspace> (i podobnych repo): czy zadeklarowana capability jest
  faktycznie WPIĘTA (registry → executor → scheduler) i WYKONYWANA, czy tylko
  istnieje w manifeście/dokumentacji. Detekcja stubów (parametry _artifact,
  validate_* bez wywołań), status-contradiction (PROPOSED vs IMPLEMENTED),
  schedule: manual bez auto-wywołania, governance-gate (deny-default/owner)
  ≠ wykonanie, orphanów (pliki bez referencji, czytające ścieżki spoza repo).
  Wynik: tabela `capability | wired? | evidence path (file:line)`.
  Używaj gdy: "czy to jest realnie wykonywane", "wired czy aspirational",
  "static or real", "capability reality audit", "czy security/knowledge/pipeline
  działa naprawdę", weryfikacja rejestrów capability (C-xxx, manifests).
type: skill
author: Hermes
version: 1.0.0
tags: [audit, truth-audit, capability, wiring, aspirational-vs-real, security, <workspace>]
---


# CAPABILITY WIRING TRUTH AUDIT — capability/pipeline/wiedza: WIRED+executable vs docs-only

## KIEDY UŻYĆ

- Pytanie typu: „czy capability X / pipeline Y / wiedza Z jest REALNIE
  wykonywana, czy statyczna/aspiracyjna?" (np. security, security, re-intel,
  knowledge fabric).
- Weryfikacja rejestru capability (C-xxx) — czy ID z manifestu mają realny
  executor, czy są tylko wpisami.
- Audyt, który ma się zakończyć tabelą dowodów, nie opinią.

## ZASADA NACIOSNA

**Deklaracja ≠ wykonanie.** Cztery filary dowodu, w tej kolejności, wszystkie
muszą być sprawdzone:

1. **REGISTRY SSOT** — znajdź PRAWDZIWY rejestr capability (nie dokument!),
   zanim cokolwiek ocenisz. W <workspace>: `runtime/manifests/capabilities.yaml`
   (S-*, kerneli, dispatch; ID C-xxx), NIE `config/canonical/registry.yaml`
   (to config plane: gates/profiles/kill-switches, zero ID C-xxx).
2. **EXECUTOR** — czy istnieje route/handler w api.rs, który WOŁA tę capability
   (np. `/api/v1/security/execute` → `security_execute_handler` → kernel).
3. **SCHEDULER** — czy cokolwiek wywołuje ją AUTOMATYCZNIE (cron.yaml, tick,
   hook-runner, `schedule:` w pipelines.yaml). `schedule: manual` +
   `schedule_spec: ""` = nigdy samo.
4. **KOD** — czy handler ma realną logikę, czy stub (patrz sygnatury stubów).

## SZABLON SOND (6 kroków + orphan check)

1. **Registry**: `grep -rn "C-[0-9]{3}" runtime/manifests/` — znajdź SSOT i listę ID.
2. **Executor**: `grep -n 'route("/api/v1/<capability' runtime/crates/aigon-runtime/src/api.rs` — śledź route → handler → kernel/tool.
3. **Scheduler**: `grep -n "command:" config/cron.yaml` (pełna lista!) + `grep -n "schedule:" config/canonical/pipelines.yaml` + `config/canonical/hooks.yaml`.
4. **Stuby**: szukaj sygnatur (patrz niżej).
5. **Status-contradiction**: porównaj `Status:` w nagłówku skryptu vs `status:` w pipelines.yaml.
6. **Governance ≠ execution**: deny-default/owner/requires_approval = framework ZGÓD, nie wykonania.
7. **Orphan check**: plik istnieje, ale zero referencji (`grep -rn nazwa-pliku repo`) LUB czyta ścieżkę spoza repo.

## SYGNATURY STUBÓW (szybki klasyfikator — widzisz, to jest stub)

| Sygnatura | Znaczenie |
|---|---|
| `fn evaluate(&self, _artifact: &Artifact, ...)` — parametr z podkreślnikiem | ignoruje artifact; wynik nie zależy od danych (np. `PolicyCoordinator::evaluate` zwraca Allow gdy `!requires_proof()`) |
| `validate_external(...)` zwraca `!content.is_empty() && audit_enabled` | nie woła ŻADNYCH zewnętrznych checków (IntegrationAdapter) |
| tablica stałych wzorców jako cała "detekcja" (eval(, system(, password=...) | tylko statyczna lista, brak logiki indykatorów kompromitacji |
| `status: IMPLEMENTED` w YAML vs `Status: PROPOSED` w nagłówku skryptu | YAML kłamie; wierz nagłówkowi + dowodowi wykonania |

## PITFALL (host <workspace>)

- Komendy terminalowe z substytucją powłoki w środku (`sed -n "$(grep -n ... | cut -d: -f1),+40p"`)
  są BLOKOWANE przez hardline parser. Rozbijaj na osobne proste grep-y, potem
  sed z literalnym numerem linii.
- Pusty wynik grepa = ODPOWIEDŹ („nie ma"), nie błąd — zapisz fakt.

## WYNIK

Tabela dowodów (wymagany format):
`capability | wired? (TAK/BRAK/TYLKO NA ŻĄDANIE/STUB) | evidence path (file:line)`
+ werdykt jednym zdaniem: co jest realne, co gated, co docs-only.

Konkretne ścieżki/linie dla <workspace> (stan 2026-09-15): patrz `references/capability-wiring-probes.md`.