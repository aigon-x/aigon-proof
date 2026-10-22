# Panel ról → graf decyzyjny → bramka pokrycia (przepis zmierzony 2026-10-18)

Cel: zamienić „panel ekspertów" z dokumentu w **sterowanie** — każda rola ma w grafie
krawędzie do bramek, skilli i praw, a bramka pilnuje, że nowa rola nie zostanie sierotą.

## 1. SSOT ról

`config/canonical/expert-panel.yaml`:

```yaml
layers: {L0: 'Host i żelazo', L1: 'Storage i trwałość danych', L2: 'Runtime i platforma'}
roles:
  - {slug: storage-architect, layer: L1, name: 'Storage Architect',
     artifact: 'storage-mount-law.yaml', metric: 'dane w tierze %',
     patterns: [storage, mount, nfs, zfs, tier, nas]}
  - {slug: support-engineer, layer: L6, name: 'Support/Ops Product Eng.',
     artifact: 'ticket→defect', metric: '% z przyczyną',
     patterns: [support, ticket, helpdesk],
     no_instrument: 'brak bramki i skilla — temat do zbudowania'}
law_owners:
  LAW-STORAGE-MOUNT-1: storage-architect
```

Kontrakt: rola bez `artifact` **i** `metric` nie wchodzi do grafu (byłaby teatrem).
Rola bez dopasowań musi mieć `no_instrument` — inaczej bramka pokrycia FAIL-uje.

## 2. Idempotentny linker (osobny skrypt, NIE patch generatora)

`scripts/panel-graph-link.py` — ładuje SSOT + `decision-graph.yaml`, **usuwa** wcześniejsze
węzły `kind=role` i krawędzie `role_*`, potem dopisuje od nowa:

```python
panel = yaml.safe_load(PANEL.read_text()) or {}
doc   = yaml.safe_load(GRAPH.read_text()) or {}
nodes = [n for n in doc['nodes'] if n.get('kind') != 'role']
edges = [e for e in doc['edges'] if not str(e.get('rel','')).startswith('role_')]

gate_nodes = [n for n in nodes if n.get('kind') == 'gate']
skill_ids  = {n['id'] for n in nodes if n.get('kind') == 'skill'}

def hit(patterns, *texts):                      # dopasowanie po fragmencie, lowercase
    blob = ' '.join(str(t).lower() for t in texts if t)
    return any(p.lower() in blob for p in (patterns or []))
```

Trzy relacje i ich character:
| relacja | dopasowanie | confidence |
|---|---|---|
| `role_owns_gate` | patterns vs nazwa/script/domain bramki | `heuristic` |
| `role_guides_skill` | patterns vs nazwa skilla | `heuristic` |
| `role_enforces_law` | **jawne** `law_owners` z SSOT | `explicit` |

**Nie udawaj pewności**: krawędzie heurystyczne mają `confidence: heuristic` w polu —
graf ma pokazywać, co jest zmierzone, a co dopasowane wzorcem.

## 3. Tryb `--check` (używany przez bramkę)

```python
roles = [r['slug'] for r in panel['roles']
         if r.get('slug') and not str(r.get('no_instrument') or '').strip()]
orphan = [r for r in roles if by_role.get(f'role:{r}', 0) == 0]
missing_law = [l for l in panel.get('law_owners', {}) if f'law:{l}' not in node_ids]
return 1 if (orphan or missing_law) else 0
```

Dodaj override ścieżki SSOT (`AIGON_PANEL_FILE`) — bez tego dowód negatywny wymaga
modyfikacji repo.

## 4. Bramka pokrycia + dowód negatywny

```bash
tools/gates/panel-graph-coverage.sh            # 0=PASS, 1=FAIL
tools/gates/panel-graph-coverage.sh --selftest # 2/2: realny panel → 0, wstrzyknięta sierota → 1
```

Selftest tworzy kopię SSOT w `mktemp -d`, dopisuje rolę z `patterns: [nieistniejacy-wzorzec]`
i uruchamia `AIGON_PANEL_FILE=<tmp> python3 panel-graph-link.py --check`, oczekując **rc=1**.
To jest prawdziwa kontrola ujemna — bez niej bramka może być ślepa i nikt tego nie zauważy.

## 5. Wpięcie w potok (bez tego krawędzie znikają)

`config/cron.yaml` — regeneracja grafu MUSI wołać linker w tym samym poleceniu:

```
python3 scripts/decision-graph-generate.py >> LOG 2>&1 \
  && python3 scripts/panel-graph-link.py >> LOG 2>&1
```

Zmierzone: bez tego następny cykl crona wygenerował graf bez ról, a `--check` zwrócił
`rc=1` na „realnym panelu" — czyli bramka poprawnie wykryła regresję, którą sami
wprowadziliśmy brakiem wpisu w cronie.

## 6. Pułapki operacyjne (kosztowały po turze każda)

1. **Regex-patch 900-liniowego generatora = SyntaxError.** Blok dopisany przez
   `str.replace` wylądował w środku literału dict. Ratunek bez `git checkout`
   (blokada `index.lock` innego agenta): `git show HEAD:scripts/x.py > scripts/x.py`,
   potem `python3 -m py_compile`.
2. **Masowa edycja YAML kanonu.** Dopisanie `panel_meta` do 10 plików uszkodziło 8, bo
   `verification: tool: tools/gates/x.sh` nie jest poprawnym skalarem. Buduj `new`,
   waliduj `yaml.safe_load(new)`, zapisuj tylko gdy parsuje.
3. **Uprawnienia plików kanonu** (`aigon:aigon 644/664`) — po `write_file`/edycji
   `chown sniegul:aigon` + `chmod 664`, inaczej następny zapis dostaje `PermissionError`
   (dotyczy `decision-graph.yaml`).
4. **Idempotencja to nie kosmetyka.** Linker uruchomiony dwa razy musi dać identyczną
   liczbę krawędzi; inaczej cron mnoży węzły przy każdym cyklu.

## 7. Liczby z sesji (punkt odniesienia)

- 39 ról w 8 warstwach → 39 węzłów `kind=role`, **2 926 krawędzi** (2 677 heurystycznych
  + jawne `role_enforces_law`), graf 3 846 węzłów / 20 607 krawędzi.
- Role bez ani jednej bramki po pierwszym pomiarze: `hardware-reliability`,
  `corpus-engineer`, `routing-policy`, `support-engineer`, `finance` — to jest lista
  robocza do zbudowania instrumentów, nie „raport".
- Skrajna proporcja wiedza/pilnowanie: `ux-researcher` 182 skille / 4 bramki,
  `routing-policy` 41 / 0, `ml-platform` 68 / 4.
