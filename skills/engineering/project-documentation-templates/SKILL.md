---
name: project-documentation-templates
description: Szablony dokumentacji dla KAŻDEGO typu projektu (mobile/Android, web frontend, backend, infrastruktura/runtime, landing, gra Roblox, CLI, ML). Użyj, gdy generujesz dokumentację techniczną lub produktową dla nowego/istniejącego projektu — wybierz szablon wg typu i wypełnij REALNYMI danymi (nie aspiracjami).
---


# Szablony dokumentacji projektów

Użyj, gdy trzeba wygenerować dokumentację (techniczną/produktową) dla projektu.
Wybierz szablon wg TYPU projektu, skopiuj i wypełnij REALNYMI danymi z repo
(ścieżki, porty, schemat, uprawnienia) — NIE szablonem bez treści, NIE aspiracjami.

## Typy projektów i szablony

| Typ projektu | Szablon | Kiedy |
|---|---|---|
| Aplikacja mobilna (Android) | `references/mobile-app.md` | INORG (PhoneGuard, SpySkaner, Pluskwa...) |
| Frontend web (React/Next.js) | `references/web-frontend.md` | panele, dashboardy (akceleratory, agent-sniegul) |
| Backend / mikrousługa | `references/backend-service.md` | grants-service, data-service, aigon-runtime |
| Infrastruktura / runtime / mesh | `references/infrastructure.md` | Docker compose, MCP, Vault, mail, monitoring |
| Landing page | `references/landing-page.md` | landingi produktów |
| Gra (Roblox/Luau) | `references/game-roblox.md` | gry Mikołaja, Roblox |
| CLI / narzędzie | `references/cli-tool.md` | aigon-code |
| ML / trening modeli | `references/ml-training.md` | voice training, modele LLM |

## Jak używać

1. Ustal TYP projektu (tabela wyżej).
2. `skill_view(name='project-documentation-templates', file_path='references/<typ>.md')` — pobierz szablon.
3. Wypełnij REALNYMI danymi: ścieżki (`docker inspect`, `ls`), porty, schemat DB (`\d`), uprawnienia (`AndroidManifest.xml`), zmienne env.
4. Zapisz w repo (np. `docs/DOKUMENTACJA-TECHNICZNA.md`) + `chown sniegul:aigon && chmod 664`.

## Żelazne reguły

- **Autorytet = kod i pomiar, nie README marketingowe.** README bywa aspiracyjne (np. grantmaster wspomina Kong/Weaviate/OpenAI — nie jest wdrożone).
- **Nie dokumentuj aspiracji jako stanu.** W sekcji „stan budowy" pisz faktyczny stan (✅/⬜/🟡).
- **Zaznacz pułapki:** co jest kanoniczne i NIE wolno usuwać (np. reedsolomon w data-service).
- **Realne ścieżki i komendy**, nie pseudokod.
