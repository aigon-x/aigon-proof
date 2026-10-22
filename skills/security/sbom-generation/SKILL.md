---
name: sbom-generation
description: Generowanie i zarządzanie SBOM (Software Bill of Materials) — spis zależności w standardzie CycloneDX/SPDX, weryfikacja podpisów, porównanie z bazą CVE, polityka licencji. Użyj przed release'em i w audycie supply chain.
---


# SBOM Generation

**Purpose:** Wyprodukować dokładny, maszynowo czytelny spis wszystkich komponentów
oprogramowania (biblioteki, narzędzia, artefakty) wraz z wersjami i licencjami —
fundament audytu łańcucha dostaw i zgodności.

**When to use:** Przed każdym release'em, przy budowie artefaktów do dystrybucji,
przy audycie supply chain, przy zmianie ekosystemu zależności, cyklicznie w CI.

## Checklist (odhaczaj wszystkie)

### Generowanie

- [ ] Narzędzie dopasowane do artefaktu (np. Syft, Trivy, CycloneDX CLI, SPDX tools, `cargo sbom`, `pip freeze` jako fallback).
- [ ] SBOM wygenerowany z faktycznego stanu (lockfiles/zbudowanych artefaktów), nie z deklaracji.
- [ ] Format standardowy: CycloneDX (JSON) lub SPDX — nie format własny.
- [ ] SBOM obejmuje: komponenty bezpośrednie i przechodnie, wersje, identyfikatory (purl), licencje.
- [ ] SBOM zapisany jako artefakt release'u (np. w katalogu dystrybucji), z wersją projektu.

### Weryfikacja

- [ ] SBOM ma spójną strukturę (walidacja schematu JSON, np. przez oficjalne schema narzędzia).
- [ ] Podpisy/checksumy artefaktów zweryfikowane tam, gdzie są dostępne (integralność, nie tylko spis).
- [ ] Różnica między SBOM-em a manifestem: brakujące komponenty wyjaśnione.

### Analiza

- [ ] Porównanie SBOM z bazą podatności (np. Grype/Trivy na SBOM, OSV) — podatne komponenty wskazane.
- [ ] Przegląd licencji: komponenty o licencjach restrykcyjnych (GPL, AGPL, SSPL) oznaczone i zaopiniowane.
- [ ] Komponenty nieznane/podejrzane (podejrzany purl, brak informacji o autorze) wskazane do ręcznej weryfikacji.
- [ ] Polityka: lista dozwolonych licencji i progi podatności zdefiniowane przed analizą.

### Proces

- [ ] Generowanie SBOM zautomatyzowane w CI (krok build), dołączane do każdego release'u.
- [ ] Dokumentacja: jak zregenerować SBOM i gdzie jest przechowywany.
- [ ] Raport końcowy: liczba komponentów, znalezione podatności, problemy licencyjne, akcje.

## Rules

- **SBOM to artefakt, nie notatka:** zapisany w repo/release'u, odtwarzalny z CI.
- **Dokładność ponad wygodę:** SBOM z deklaracji (bez lockfile) nie jest wiarygodny — generuj z faktycznych artefaktów.
- **Licencje i CVE razem:** SBOM bez analizy licencji i podatności to tylko inwentarz, nie kontrola.
- **Aktualność:** SBOM wersjonowany razem z artefaktem — stary SBOM przy nowym release'u to błąd.

<!-- DO NOT EDIT — managed by sync-agent-models.py (sync_skills); SSOT: skills/shared/ -->
