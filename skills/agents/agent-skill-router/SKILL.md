---
name: agent-skill-router
description: "Wspólny rdzeń wszystkich agentów AIGON-X: ładuje prawa i rdzeń skilli, następnie dobiera specjalistyczne skille, narzędzia, capabilities oraz mesh do zadania."
---


# Agent Skill Router

Stosuj przed każdym zadaniem. Ten skill jest wspólny dla Qwen, Claude, Hermes,
Grok, aigon-code, Codex, DSH i Gemini; adapter CLI nie zmienia procedury.

## Kolejność wejścia

1. Wczytaj obowiązujące prawa i kanon projektu.
2. Wczytaj `doskonalosc-100plus`: cel, metryki, granice, dowód i kanoniczna
   trasa przed zmianą.
3. Wczytaj `napierdalacz` dla wykonania wymagającego wielu niezależnych prac.
4. Wybierz wyłącznie skille potrzebne do domeny zadania. Nie ładuj katalogu
   skilli w ciemno.

## Kategorie skilli

| Kategoria | Kiedy wybierać |
|---|---|
| agent / runtime / llm | modele, bramka, kontekst, sesje, routing, agent CLI |
| mcp / capabilities | discovery narzędzi, MCP, adaptery, capability binding |
| mesh / swarm | praca równoległa, task_execute, węzły, kolejki, failover |
| observability | health, metryki, logi, alerty, evidence |
| deployment / infrastructure | build, obraz, usługa, sieć, node, storage |
| data / secrets / vault | poświadczenia, dane, migracje, retencja |
| product / design | produkt, UI, dostępność, publikacja, monetyzacja |
| security / verification | bramki, test negatywny, audyt, bezpieczeństwo |

Jeżeli kategoria jest niejasna, użyj `skills_list` i `skills_get`; decyzji nie
opieraj na samej nazwie katalogu.

## Narzędzia i capabilities

**MCP jest domyślną drogą do wszystkiego, co jest przez MCP dostępne**: stanu,
wiedzy, pamięci, capabilities, zadań, mesha i dowodów. Nie obchodź go
bezpośrednim HTTP, SSH ani zgadywaniem portów. Shell służy wyłącznie do
lokalnych plików i narzędzi, których MCP nie wystawia.

1. Najpierw sprawdź stan przez `runtime_health`, `runtime_status` i właściwe
   capability discovery; potem wykonuj zmianę.
2. Wiedzę pobieraj przez `knowledge_search` / `knowledge_get`, a pamięć przez
   `memory_search` przed przeszukiwaniem dysku.
3. Każdą capability uznaj za dostępną dopiero po realnym wyniku, nie po liście
   ani deklaracji konfiguracji.
4. Używaj jednego kanonicznego MCP `aigon-code` przez lokalną bramkę; nie
   omijaj go bez jawnego polecenia Suwerena.

## Mesh i swarm

1. Dla pracy masowej lub niezależnych gałęzi użyj `task_execute`; sprawdź
   `task_status` oraz `subtasks[].node` jako dowód rozproszenia.
2. Najpierw zmierz mesh i obciążenie. Węzeł z `load1 >= cores` nie przyjmuje
   nowej pracy.
3. Zwiadowca przygotowuje jeden brief; wykonawcy dostają wyłącznie własny
   zakres. Nie powielaj czytania monolitu przez każdy węzeł.
4. Brak dostępnego hopu nie jest sukcesem ani porażką ukrytą: zlecenie zostaje
   queued z powodem i retry.

## Zakończenie

Wynik wymaga dowodu z niezależnego pomiaru. Po zmianie sprawdź aktywnie
załadowaną kopię konfiguracji i wykonaj rzeczywiste żądanie tą samą ścieżką,
którą używa agent.
