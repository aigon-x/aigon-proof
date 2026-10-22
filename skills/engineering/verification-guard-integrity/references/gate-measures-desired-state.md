# Bramka mierząca NIE TĘ warstwę — dwie klasy zmierzone 2026-10-01

Obie blokowały commit/push **całej flocie agentów**, a obie były defektem DETEKTORA,
nie stanu systemu. Wzorce warte sprawdzenia przy każdej bramce, którą piszesz.

## Klasa 1: bramka czyta DRZEWO ROBOCZE zamiast STANU ZAMIERZONEGO (git)

**Objaw:** pre-commit `registry-coherence` FAILował:
```
[FAIL] REGCOH-003 każdy produkt z plików jest w bazie
       10 produktów BEZ wpisu w bazie: agent, agents-k1-k13, aito, app, archive,
       artifacts, assets, audit-2026-09-28, audyt, ...
[CERTIFICATION: FAIL]   -> commit zablokowany
```

**Przyczyna:** bramka budowała listę produktów przez
`find "$CANON_DIR" -mindepth 1 -maxdepth 1 -type d` — czyli po **working tree**.
Na węźle leżało tam **155 katalogów**, z czego **113 NIEŚLEDZONYCH** (`??`): śmieci
po niepodstawionych globach — w tym katalog dosłownie nazwany `*` — oraz cudze WIP
(`_diag/`, `_work/`, `E2E_ACC/`, `PAKIETY_*`). Baza rejestru ma 45 wpisów; porównanie
z drzewem roboczym musiało FAILować.

**Kontrast wewnątrz TEJ SAMEJ bramki:** REGCOH-004 i REGCOH-005 miały już wbudowane
odroczenie („NIE ROZSTRZYGAM na węźle local-aigon — SSOT kanonu = prod.szamani.ai;
lokalne drzewo canon jest z definicji niepełne"), a REGCOH-003 nie — czyli bramka
przeczyła sama sobie.

**Naprawa (wzorzec):** mierzyć stan ZAMIERZONY, nie katalog:
```bash
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$ROOT" ls-tree -d --name-only "HEAD:${CANON_DIR}" | sed 's#.*/##' | grep . | sort
fi
# fallback na find TYLKO gdy brak gita (kopia bez .git)
[ -s "$LISTA" ] || find "$CANON_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
```
Pomiar przed/po: `find` = 155, `git ls-tree` = 42 → `REGCOH-003 PASS`,
`CERTIFICATION: PASS`.

**Reguła ogólna:** jeśli bramka porównuje „co jest na dysku" z rejestrem, zapytaj
najpierw: **czy dysk to stan zamierzony, czy śmietnik roboczy?** Bramka mierząca
working tree łapie cudze WIP i śmieci — i karze za nie wszystkich.

## Klasa 2: klucz / deklaracja BEZ KONSUMENTA w bramce

**Objaw:** do SSOT `config/canonical/<prawo>.yaml` dopisany nowy warunek
(`w6_*`), a bramka go nie czyta. Formalnie „prawo istnieje", faktycznie — deklaracja.

**Reguła (klasa „0 użyć = luka"):** nowa reguła jest wpięta dopiero, gdy ma
**wszystkie trzy** warstwy:
1. klucz w manifeście SSOT (z kontraktem i dowodem pomiarowym w komentarzu),
2. **odczyt w bramce** (`grep -c '<klucz>' tools/gates/<bramka>.sh` ≠ 0) —
   inaczej klucz jest martwy,
3. metryka/dowód przebiegu (u nas `aigon_mesh_duty_condition_ok{condition="w6"}`).

**Wzorzec wpięcia (sprawdzony):** warunek + `[FAIL]`/`[PASS]`/`[WARN]` + inkrementacja
licznika naruszeń + wpis do pętli metryk + **test negatywny** (celowo zepsuj → MUSI
paść; przywróć → MUSI przejść). Bramka bez kontroli negatywnej jest dekoracją.

**Praktyczna konsekwencja:** po dopisaniu klucza sprawdź, czy bramka nadal się
uruchamia (`bash -n` + przebieg), bo klucz nieobsługiwany = cisza, a cisza
wygląda jak PASS.
