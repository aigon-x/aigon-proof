# Write-Path / Verify-Path Payload Inconsistency

## The Bug

Subagent wrote two functions:
- `recordAudit()` — inserts an audit log entry with a hash-chain
- `verifyAuditChain()` — verifies the hash chain

Both functions called `computeAuditHash(entry, prevHash)` which:
```
JSON.stringify({ ...entry, prev_hash: prevHash }) + prevHash → SHA-256
```

**The mismatch:** `recordAudit()` passed a record that INCLUDED `hash: ''` (set before computing), but `verifyAuditChain()` destructured `hash` out before passing. JSON strings differed by `, "hash": ""`. Typecheck passed. The test caught it.

## Detection

TypeScript typecheck (0 errors) — no warning.

Test (`npm test`): 1/256 failed — `verifyAuditChain()` returned `{ valid: false }` because recomputed hash didn't match stored hash.

## Fix

```diff
- record.hash = computeAuditHash(record, prevHash);
+ const { hash: _h0, ...recordForHash } = record;
+ record.hash = computeAuditHash(recordForHash, prevHash);
```

Align the verify path with the record path — remove `hash` from both before computing.

## Broader Pattern

This is **not** a subagent-specific bug. It's a general code generation problem: when two pieces of generated code must produce identical serialized representations, any asymmetry in field inclusion (zero values, null vs absent, key order) breaks the contract. The write path and verify path must produce byte-identical canonical input to the hash function.

## Mitigation for Generated Code

1. After generating write+verify pair, add a test that exercises both end-to-end and asserts `result.valid === true`
2. Do NOT rely on typecheck alone — the types match, the payloads don't
3. Trace the EXACT value being serialized in write path vs verify path by comparing `JSON.stringify()` output from both sides
4. Use a single shared helper for payload construction — never construct the payload independently in write and verify paths
