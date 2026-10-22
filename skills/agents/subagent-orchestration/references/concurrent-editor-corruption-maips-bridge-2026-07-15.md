# Concurrent Editor Corruption — maips_bridge.rs (2026-07-15)

## Scenario

Three sibling subagents were dispatched in parallel to fix build errors in `<workspace>/runtime/crates/aigon-mesh/src/maips_bridge.rs`.

All three agents attempted to add `MaipsPayload::Discovery` and `MaipsPayload::Register` match arms to the `handle_deferred` function's non-exhaustive match block (line 276).

## What Happened

Each agent's `patch` call succeeded independently because they all targeted slightly different regions of the match block. The merged result had:

1. **Correct arms** (lines 319-321) from the first agent to apply
2. **Orphaned duplicate arms** (lines 323-326) from the second agent, with no parent `match` keyword
3. **A wildcard `_ => {}`** (line 325) from a third agent, also orphaned

The resulting file had balanced braces (each agent's edit was structurally self-consistent) but semantically invalid structure — a dangling arm expression between `}` `}` and `}` `}` `}`.

Example of the corrupted state:
```rust
            }                                    // close Batch arm
        }                                        // close match (first agent)
    }                                            // close handle_deferred (first agent)
            MaipsPayload::Discovery { .. } | MaipsPayload::Register { .. } => {  // ORPHANED
                debug!("[MAIPS Bridge] deferred received discovery/register...");
            }
        }                                        // orphaned close-match
    }                                            // orphaned close-function
```

Only `cargo check` caught the problem — file structure looked correct to human inspection.

## Root Cause

Multiple subagents writing to the **same file** in parallel. The `patch` tool's fuzzy matching allowed each to succeed against the base file, but the merged result combined all their changes without coordination.

## Fix Applied

A cleanup agent re-read the file, identified the orphaned blocks by comparing against the known-good structure from the original (361-line) file, and removed the duplicate arms with a targeted `patch` call using enough context to uniquely match the offending region.

## Lesson

**Never dispatch two subagents to edit the same file.** If multiple independent edits are needed on one file, serialize those tasks and parallelize other, non-conflicting files. Even if all patches succeed independently, the merged result can be structurally corrupted.

When recovery is needed:
1. Re-read the full file
2. Identify orphaned code (code between closing braces with no enclosing function)
3. Run `cargo check` for the authoritative structural test
4. Apply a single, targeted patch to remove orphaned sections
5. Re-add any missing changes with a single coordinated edit
