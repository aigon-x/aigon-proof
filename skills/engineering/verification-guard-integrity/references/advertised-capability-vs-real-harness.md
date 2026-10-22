# Advertised capability vs real — empirical correctness harness

Zmierzone 2026-10-01 (`<workspace>`, audyt RS #2, Reed-Solomon).

## Klasa problemu

Kod/deklaracja obiecuje **zdolność** (tolerancja N utrat, auto-recovery, FEC,
rekonstrukcja z redundancji), a test w repo **nie dowodzi**, że ta zdolność
realnie zachodzi na ścieżce, o której myślisz. Testy mogą:
- przechodzić tylko na **trivialnej ścieżce** (wszystkie dane obecne),
- asertować **słabo** (`!is_empty()`, `is_ok()`, `len > 0`) — przejdą na
  uszkodzonych danych,
- mierzyć **inną ścieżkę** niż produkcyjna (endpoint woła starszą implementację).

To rodzina fałszywego zielonego, ale jej sedno: **obietnica zdolności ≠ pomiar
zdolności**. Nie wystarczy „testy przechodzą" — trzeba pokazać, że test
*realnie egzekwuje* obietnicę.

## Wzorzec harnessa (reprodukowalny)

Dla dowolnej zdolności „odtwórz X po utracie/uszkodzeniu Y":

1. Zbuduj payload **deterministyczny, niezerowy, o długości NIE będącej
   wielokrotnością rozmiaru bloku/sharda** (łapie błędy paddingu/trimu).
2. Zakoduj → **usuń/zniszcz DOKŁADNIE te elementy, których dotyczy obietnica**
   (dla RS: shardy DANYCH, nie parity).
3. Odtwórz.
4. **Porównaj bajt-w-bajt z oryginałem** (`assert_eq!(healed, data)`) — NIGDY
   `!is_empty()`.
5. Dodaj przypadek **poza tolerancją** — MUSI zwrócić błąd, nie śmieci.
6. Dodaj przypadek graniczny rozmiaru (1 bajt, 2 bajty, payload kończący się
   zerem) — łapie padding/trim.

### Szkielet (Rust, ale wzorzec jest językowo-agnostyczny)

```rust
fn encode_drop_heal(data: &[u8], drop: &[usize]) -> Result<Vec<u8>, String> {
    let shards = fs.reed_solomon_encode(data, DS, PS)?;
    let mut input: Vec<Option<Vec<u8>>> = shards.iter().enumerate()
        .map(|(i, s)| if drop.contains(&i) { None } else { Some(s.data.clone()) })
        .collect();
    fs.reed_solomon_heal(&input, DS, PS)
}

#[test]
fn lose_data_shard_reconstructs_exactly() {
    let data = payload(1000);           // niezerowy, nie-wielokrotność
    assert_eq!(encode_drop_heal(&data, &[0]).unwrap(), data);  // STRICT
}
```

Uruchomienie i cytowanie wyniku **do raportu**:
```
cargo test -p <crate> --test <harness> -- --nocapture
```

## Zmierzone wyniki (RS audit)

Konfiguracja `data_shards=4, parity_shards=2`:

| Miejsce | Algorytm | Deklarowana tolerancja | Rzeczywista | Length-safe |
|---|---|---|---|---|
| `aigon-fs/canonical_fs.rs::reed_solomon_*` | RS GF(2⁸), `reed-solomon-erasure 6.0` | 2 | **2 (działa bajt-w-bajt)** | ❌ trim trailing zer |
| `aigon-magic-router/fec.rs` | RS GF(2⁸) | 2 | **2** | ✅ `original_len` |
| `aigon-fs` legacy `erasure_encode`/`heal` | XOR single-parity | reklamowane 2 | **tylko 1** ← ROZJAZD | ✅ length-prefix |
| `POST /api/v1/fs/replicate` (api.rs) | legacy XOR (4,2) | 2 | **1** | — |

Wniosek: RS **realnie rekonstruuje shardy DANYCH z parity** (17/17 testów
harnessa PASS). ALE ścieżka produkcyjna `/api/v1/fs/replicate` używa legacy XOR,
która toleruje 1 utratę, mimo że odpowiedź API mówi `"parity_shards": 2`.

## Trzy pitfall-e tej klasy

### A. Słaba asercja maskuje brak zdolności
`canonical_fs.rs::test_reed_solomon_missing_shards` usuwał 2 shardy, ale
asertował `assert!(!healed.is_empty())`. Przeszedłby nawet gdyby heal zwrócił
**całkowicie inne bajty**. Wzorzec: **każdy test „odzyskiwania/rekonstrukcji"
musi kończyć się porównaniem z oryginałem.**

### B. Advertised ≠ real (endpoint na innej implementacji)
Endpoint deklarował `parity_shards: 2` w JSON, ale wołał ścieżkę, której
własny guard odrzucał >1 utratę (`"at most 1 missing shard"`). **Sprawdź, KTÓRĄ
implementację woła endpoint produkcyjny**, nie tylko czy w repo istnieje
poprawna wersja. Zwykle są dwie: nowa (dobra) i legacy (używana).
Grep: `grep -rn '<nazwa-fn>' runtime/crates/*/src/api.rs` — co realnie woła.

### C. Trim/padding bez length-prefix = cicha korupcja danych binarnych
`reed_solomon_heal` ucinał końcowe zera (`while result.last() == Some(&0) { pop }`),
bo nie przechowywał oryginalnej długości. Payload binarny kończący się `0x00`
zostaje zrekonstruowany **obcięty**. Kontrast: `fec.rs` ma `original_len` w
`FecFrame` i jest odporny. **Reguła: każda rekonstrukcja bez pola długości jest
podejrzana o utratę danych binarnych.** Test: payload + trailing zero.

## Bramka końcowa

- [ ] Test porównuje z oryginałem bajt-w-bajt (nie `!is_empty`).
- [ ] Utrata dotyczy elementu, o którym mówi obietnica (dane, nie redundancyjne).
- [ ] Przypadek poza tolerancją zwraca BŁĄD (nie śmieci).
- [ ] Sprawdzono, KTÓRĄ implementację woła endpoint produkcyjny.
- [ ] Deklarowana tolerancja == zmierzona (różnica = defekt, nie „dokumentacja").
- [ ] Wynik wklejony do raportu z surowym `test result: ok. N passed`.
