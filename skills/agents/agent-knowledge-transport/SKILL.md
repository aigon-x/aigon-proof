---
name: agent-knowledge-transport
description: Użyj, gdy fakt operacyjny/lekcja ma przetrwać między sesjami i agentami — gdzie go zapisać (pamięć lokalna vs repozytorium vs kanoniczna warstwa wiedzy AIGON Runtime), dlaczego pamięć lokalna się blokuje i jak ją odciążyć, oraz jak zapisać wiedzę, gdy narzędzie odmawia. Zawiera zmierzoną kaskadę nośników i kolejność awaryjną. Użyj gdy zadanie dotyczy — Użyj, gdy fakt operacyjny/lekcja ma przetrwać między sesjami i agentami.
---


# Transport wiedzy agenta — gdzie ma trafić fakt

Problem: agent ustala coś cennego (root cause, procedurę, pułapkę) i musi ją
zapisać tak, żeby **przetrwała sesję i dotarła do innych agentów**.

## Nośniki — w kolejności wyboru

| # | Nośnik | Kiedy | Trwałość |
|---|---|---|---|
| 1 | **Kanoniczna warstwa wiedzy AIGON Runtime** | fakty operacyjne, procedury, lekcje | SSOT, widoczna dla floty |
| 2 | **Repo (`<workspace>`)** — config/docs/skills | fakty o projekcie, konwencje, manifesty | wersjonowana, audytowalna |
| 3 | **„Skills" agenta** | JAK wykonać klasę zadania | wersjonowana |
| 4 | **Pamięć lokalna agenta** | kim jest user, bieżący stan operacji | **limitowana, ulotna** |

Trzy warstwy runtime (z `runtime/manifests/knowledge.yaml`):
1. **SSOT (dysk)** — `<workspace>/runtime/knowledge` (24 kategorie + encyclopedia),
2. **INDEX (Qdrant)** — kolekcja `knowledge_v2` (768-dim, nomic-embed-text),
3. **API (Postgres `aigoncode`)** — `knowledge_sources` dla wpisów
   user-generated (`source_type`: runtime/deployment/project/recon/json),
   izolacja tenantów przez `tenant_id`.

Fakt typu „produkt X działa na węźle Y, deploy komendą Z" to
**`source_type: deployment`** → warstwa 3.

W istniejącej infrastrukturze jest już przenoszenie wiedzy agentów do runtime:
`scripts/sync-agent-memory.py` (cron `*/5`). Sprawdź, czy Twoja lekcja nie
powinna iść tam, zanim wymyślisz nowy nośnik.

## PITFALL: pamięć lokalna się BLOKUJE (i to nie awaria)

Zmierzone: pamięć Hermesa to **plik tekstowy** (`~/.hermes/memories/MEMORY.md`),
z twardym limitem ~8000 znaków. Gdy jest pełna (np. 7954/8000), KAŻDY zapis
przekraczający limit jest odrzucany — a po kilku próbach narzędzie odmawia
dalszych zapisów na całą turę.

Objaw: „czemu pamięć jest zablokowana?". Odpowiedź: **jest pełna, nie zepsuta.**
Zablokowanie po N próbach to zabezpieczenie przed pętleniem, nie trwały stan.

Co robić zamiast pętli prób:
1. **Jedna operacja zbiorcza** (`operations: [...]`) — usuń/skróć stare wpisy
   i dodaj nowy w TYM SAMYM wywołaniu; limit sprawdzany jest dopiero po
   zastosowaniu całości, więc skonsolidowanie + dopisanie przechodzi tam,
   gdzie samo dopisanie nie przechodzi.
2. **Skróć inne wpisy** tym samym batchem (kandydują te, których treść jest
   gdzie indziej — np. duplikat wiedzy projektowej trzymanej w skillu/repo).
3. **Jeśli nadal nie przechodzi — NIE pętl.** Zapisz fakt na nośniku wyższym
   (repo/manifest) i powiedz wprost, że pamięć była zajęta. Wpis do pamięci
   dołóż w kolejnej turze.
4. **Nie zapisuj do pamięci tego, co ma dom na nośniku 1–3.** Pułapki
   wdrożenia, komendy deployu i architektura projektu należą do repo/skilla;
   pamięć trzymaj na „kim jest user" i „co teraz robimy".

Praktyka, która działa: duże fakty operacyjne zapisz w manifeście repo
(np. `config/environments.yaml` z sekcją `deploy_pulapki`), a w pamięci
zostaw tylko wskaźnik („szczegóły: `env-marker.py <projekt>`").

## PITFALL: gdy narzędzie odmawia — nie pętl, wybierz inny nośnik

Narzędzia skilli odmawiają modyfikacji skilli **ręcznie autorowanych**
(`created_by=None`). Komunikat: „Manually authored skills are off-limits to
autonomous curation".

Diagnoza i wyjścia (w tej kolejności):
1. Sprawdź, czy skill na pewno jest Twojej roboty — próba patchująca cudzy
   plik to strata tury.
2. **Dodaj wiedzę do skilla, który MOŻESZ zapisać** (nowy, klasowy umbrella
   albo ostatnio tworzony przez agenta) i **wskaż tam palcem** na ten
   niedostępny, z adnotacją co jest w nim nieaktualne.
3. Zgłoś w odpowiedzi, że skill wymaga poprawki ręcznej — nie milcz.
4. Nie próbuj obejść uprawnień inaczej niż przez jawne polecenie usera.

## Kolizje nazw skilli — pułapka blokująca narzędzia

Gdy ten sam `name` istnieje w dwóch katalogach (np. `skills/X` oraz
`skills/<kategoria>/X`), `skill_view`/`skill_manage` **odmawia zgadywania**:
„Ambiguous skill name — refusing to guess". Objaw: nie da się wczytać ani
spatchować skilla, którego nazwę widzisz na liście.

Obejście: ładuj po ścieżce z kategorią (`ops/<nazwa>`). Docelowo:
**skonsoliduj duplikat** (jeden skill, jedno miejsce) — duplikat nazwy
blokuje narzędzia na stałe. Zmierzone dla `watchdog-fleet-integrity`,
`hermes-dual-copy-verification`, `false-green-elimination`,
`verification-test-design`.

## CHECKLISTA zapisu faktu

- [ ] Wybrałem najniższy wystarczający nośnik (najczęściej repo/manifest)
- [ ] Nie duplikuję tego samego faktu w pamięci ORAZ w repo
- [ ] Zapisałem przez JEDNO wywołanie zbiorcze
- [ ] Jeśli odmowa — zapisałem na nośniku wyższym i zgłosiłem, nie pętliłem
- [ ] Wpis mówi JAK COŚ ZROBIĆ (skill), a nie „co się dziś stało" (to historia
      sesji — jest w session_search)

## DYSTRYBUCJA SKILLA TO OSOBNA PRACA — manifest NIE wystarczy (zmierzone 2026-10-16)

Wpis w manifeście (`config/agent-models.yaml` → `skills.manifest.<name>` z
`targets: [7 agentów]`) to **za mało**. `sync_skills` kopiuje do katalogów
agentów WYŁĄCZNIE skille z rdzenia kontekstu (`context_budget.skills_core`:
`always` + kategorie z `config/canonical/skill-graph.yaml`), a resztę PRUNE
usuwa. Kanon mówi wprost: **„wpis w `always` = JEDYNA trwała droga dystrybucji"**.
Kategoria grafu NIE wystarcza, jeśli nie jest w `skills_core.categories`
(zmierzone: `skill-graph-generate.py` nie zakategoryzował nowego skilla →
`always` było jedyną drogą).

Dwie pułapki przy weryfikacji, obie zmierzone:

1. **`SKIP: agent config sync lock held`** — ręczny `sync-agent-models.py`
   ustępuje instancji z crona. To NIE jest porażka: nie usuwaj cudzego locka
   (`/var/lock/aigon-sync-agent-models.lock`), poczekaj na cron albo sprawdź
   `pgrep -af scripts/sync-agent-models.py`.
2. **Watcher z terminem PRZEGRYWA z cronem** — budzik „40 × 15 s" wygasł
   ~2 min przed dostarczeniem skilla; meldunek „BRAK" był PRAWDZIWY dla chwili
   pomiaru, a fałszywy dla stanu końcowego. Weryfikuj PO FAKCIE, twardym
   pomiarem tożsamości pliku:

```bash
md5sum skills/shared/<skill>/SKILL.md
for a in .hermes .qwen .claude .grok .aigon .codex .dsh; do
  find /home/sniegul/$a/skills -maxdepth 3 -name SKILL.md -path "*<skill>*" \
    -exec md5sum {} \;
done   # ten sam md5 w SSOT i u KAŻDEGO agenta = dostarczone
```

Uwaga na `find`: za mała głębokość (`-maxdepth 3` z korzenia agenta) daje
fałszywe „BRAK" — sprawdź, że ścieżka faktycznie jest w zasięgu skanu.
