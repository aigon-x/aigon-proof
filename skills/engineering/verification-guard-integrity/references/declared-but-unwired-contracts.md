# Kontrakt istnieje, wykonawca nie (declared-but-unwired)

Zmierzone 2026-10-01 (`<workspace>`) — **cztery przypadki w jednej sesji**.

## Klasa problemu

Artefakt deklaruje zdolność w sposób **kompletny i przemyślany** — ma kontrakt,
pola, wartości domyślne, czasem 17 KB prozy projektowej — ale **nie istnieje
żaden kod, który go czyta**. Deklaracja jest poprawna. Konsumenta nie ma.

To NIE jest to samo co false-green:
- **false-green** = wynik kłamie (zwraca `ok`, choć nic nie zapisał).
- **declared-but-unwired** = nic nie kłamie, bo **nic się nie wykonuje**.
  Artefakt leży i wygląda na mechanizm. Dokumentacja udaje implementację.

Objaw rozpoznawczy: nagłówek pliku mówi „docelowo czyta to X", „interpreter
not yet wired", „Dziś: SSOT kontraktu". To **przyznanie się do braku wykonawcy**,
napisane przez autora, który wiedział i zostawił TODO zamiast mechanizmu.

## Zmierzone przypadki (wszystkie tego samego dnia, wszystkie tej klasy)

| artefakt | deklaracja | stan |
|---|---|---|
| `config/dynamic-agent.yaml` (17 KB) | pełny kontrakt subagenta: goal, compose, placement, limits, spawn_card | nagłówek: „Czyta (docelowo): runtime spawn, MCP task_execute, aigon-code SubagentTool. **Dziś: SSOT kontraktu**" — zero konsumentów |
| `runtime/manifests/agents.yaml` | 8 agentów `enabled: true`, warstwy, clone_policy | nagłówek: „Informational for v2.1+ (**AgentRegistry interpreter not yet wired**)" |
| runtime capability `S-004` | „Design scheduling, DAG building, load balancing" w katalogu `/api/v1/capabilities` | skill bez implementacji — tylko wpis opisowy |
| `config/canonical/constitution-fitness-map.yaml` | mapa LAW-id → wykonawca (fitness) | **1 wpis fitness + 1 exempt na 91 praw** — czyli 89 praw konstytucji nie ma wykonawcy |

Czwarty przypadek jest najgroźniejszy, bo konstytucja **łamała własne prawo**:
LAW-75 brzmi „Prawo bez testu jest aspiracją, nie prawem" — a sam LAW-75 był
jednym z 89 bez wykonawcy. Pokrycie 1/91 = 1,1 %.

## Metoda wykrycia (kolejność)

1. **Policz deklaracje.** `grep -c` po ID/nazwach w rejestrze (capabilities,
   prawa, agenci, kontrakty).
2. **Policz konsumentów.** Dla każdego ID sprawdź, czy istnieje kod, który je
   czyta: `grep -rn '<id>' --include='*.rs' --include='*.py' --include='*.sh'`
   z **wykluczeniem pliku, w którym ID jest zdefiniowane**.
3. **Porównaj** — różnica to liczba deklaracji bez wykonawcy.
4. **Sprawdź nagłówki** deklaracji pod frazy: `docelowo`, `not yet wired`,
   `Dziś:`, `informational`, `not implemented`, `TODO`, `wersja przyszła`.
   To najszybszy detektor tej klasy — autorzy zostawiają tam przyznanie.

Prosty licznik (wzór, dostosuj ścieżki):

```python
import re, subprocess
IDs = re.findall(r'^## (LAW-[^\s—]+)', open(PROZA).read(), re.M)
brak = []
for i in IDs:
    out = subprocess.run(
        ["grep","-rl",i,"--include=*.rs","--include=*.py","--include=*.sh",ROOT],
        capture_output=True, text=True).stdout.split()
    # odrzuć pliki definiujące (proza, rejestr, mapa)
    konsumenci = [f for f in out if not any(
        k in f for k in ("canonical/","manifests/","knowledge/01-canon"))]
    if not konsumenci:
        brak.append(i)
print(f"deklaracji={len(IDs)} bez_konsumenta={len(brak)}")
```

## Wzorzec naprawy: JEDNO ogniwo, nie lista

Naprawa tej klasy **nie polega na dopisaniu brakujących implementacji po kolei**.
Polega na znalezieniu **jednego ogniwa**, które sprawia, że deklaracja staje
się wykonywalna — a potem rozwiązaniu klasy (LAW-96 pkt 4: „napraw klasę,
nie egzemplarz").

Przykład z sesji: dla `dynamic-agent.yaml` ogniwem jest jeden komponent, który
czyta kontrakt + `goal`, komponuje zestaw (`compose`), wybiera węzeł
(`placement`) i woła `POST /runtime/agents/spawn`. Reszta pól kontraktu
**już jest** — brakowało tylko wykonawcy.

## Trzy anty-wzorce naprawy (wszystkie kuszące, wszystkie złe)

1. **„Dopiszę wpis do allowlisty i zniknie z raportu."** To uciszenie detektora,
   nie naprawa — ta sama klasa co allowlista na nieistniejący kontener.
   Zmierzone wcześniej: wpis `aigon-logrotate` w `ALLOWED_RESTART_CONTAINERS`
   dodany tylko po to, by walidator przestał krzyczeć, przy kontenerze który
   **nie istnieje**.
2. **„Zbuduję kaskadę w polu, które ma tylko udawać kaskadę."** Zmierzone:
   `delegation` w SSOT czytał **płaską parę** `model+provider`
   (`delegate_tool.py:3111`), a `fallback_chain` **nie miał konsumenta w kodzie**.
   Efekt: HTTP 402, delegacja martwa, zmierzone 6/6 i 8/8 FAIL. Pole wyglądało
   na kaskadę i nią nie było.
3. **„Dopiszę kolejny dokument opisujący zdolność."** Zwiększa licznik
   deklaracji, nie konsumentów — pogłębia problem.

## Bramka końcowa

- [ ] Policzone: deklaracje vs konsumenci — różnica podana liczbą.
- [ ] Każdy artefakt ma **wskazany plik/kod**, który go realnie czyta.
- [ ] Nagłówki bez fraz `not yet wired` / `Dziś: SSOT` (albo wpis w allowliście
      z jawnym uzasadnieniem, czemu wykonawcy nie ma).
- [ ] Naprawa przez **jedno ogniwo**, nie przez listę wpisów allowlisty.
- [ ] Test negatywny: usunięcie konsumenta → bramka krzyczy.
- [ ] Jeżeli deklaracja jest prawem/regułą — wykonawca wpisany w mapę fitness
      (`constitution-fitness-map.yaml`), nie tylko w prozę.
