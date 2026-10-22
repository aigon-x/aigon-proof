# Subagent-Generated Rust Code: Systematic Compilation Repair

## Problem

Subagents generating Rust code with `async fn` in trait implementations fail to compile because `dyn Trait` cannot hold `async fn` directly. The subagent writes:

```rust
fn transform<'a>(&'a self, ctx: &'a mut PipelineContext) -> Pin<Box<dyn Future<Output = TransformResult> + Send + 'a>> { Box::pin(async move {
    ...
    TransformResult { ... }
    }
}
```

But this is **missing**:
1. `)` to close `Box::pin(`
2. `    }` (at 4-space indent) to close the `fn transform { ... }` body
3. Balancing: 3 opens (fn `{`, Box::pin `(`, async `{`) need 3 closes (`}`, `)`, `}`)

The correct pattern is:
- `        TransformResult { ... }` — struct literal (inside async body)
- `    })` — closes async `{` + Box::pin `(`
- `    }` — closes `fn transform {`
- `}` — closes `impl Dimension {`

## Detection

### Fast check

```bash
cd <project> && cargo check 2>&1 | grep -c "^error"
```

Common error signatures:
| Error | Meaning |
|-------|---------|
| `mismatched closing delimiter: \}\}` | Extra/missing brace |
| `unclosed delimiter` | Missing brace/paren opening |
| `E0782: expected a type, found a trait` | Using `impl Trait` in `dyn` context |
| `E0277: \`Result<String, _>\` is not a future` | Non-async fn used where future expected |
| `E0753: expected outer doc comment` | `//!` before `use` statement |
| `E0670: async fn not permitted in Rust 2015` | File-specific edition detection issue |
| `future cannot be sent between threads safely` | !Send type in async block |

### Brace/paren balance trace — full character stack (programmatic)

The simple combined counter (`{+` vs `}+`) can hide mismatches when braces and parens balance independently but their combined sequences don't. Use Python with a single-character stack for precise detection:

```python
path = "/path/to/file.rs"
text = open(path).read()
lines = text.split('\n')
stack = []
for i, line in enumerate(lines, 1):
    for j, c in enumerate(line, 1):
        if c in '({':
            stack.append((c, i, j))
        elif c == ')':
            if stack and stack[-1][0] == '(':
                stack.pop()
            else:
                print(f'EXTRA ) at line {i}:{j}  context: ...{line[max(0,j-30):j+30]}...')
        elif c == '}':
            if stack and stack[-1][0] == '{':
                stack.pop()
            else:
                print(f'EXTRA }} at line {i}:{j}  context: ...{line[max(0,j-30):j+30]}...')
print(f'Remaining on stack: {len(stack)}')
for s in stack:
    print(f'  Unmatched: {s[0]} at line {s[1]}:{s[2]}')

# Cross-check with independent counts:
o_paren = text.count('(')
c_paren = text.count(')')
o_brace = text.count('{')
c_brace = text.count('}')
print(f'( : {o_paren}  ) : {c_paren}  diff: {o_paren-c_paren}')
print(f'{{ : {o_brace}  }} : {c_brace}  diff: {o_brace-c_brace}')
```

This reveals exactly WHICH line has the extra/missing delimiter, not just that a mismatch exists.

Unlike `cargo check`, this tool works even when unrelated files in the workspace have pre-existing compilation errors. Run it as a first-pass diagnostic before attempting any fixes.

## Systematic Fix Patterns

### Pattern 1: E0753 (inner doc comments before `use`)

`//!` doc comments before `use` statements are inner doc comments not attached to any item. In Rust 2021+ these are errors.

**Fix:** Convert `//!` to `//` (regular comment) across all files:

```python
import os
for fn in os.listdir(dims_dir):
    path = os.path.join(dims_dir, fn)
    with open(path) as f:
        content = f.read()
    lines = content.split('\n')
    new_lines = []
    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith('//!'):
            # Check next non-empty line
            next_line = ''
            for j in range(lines.index(line)+1, len(lines)):
                if lines[j].strip():
                    next_line = lines[j].strip()
                    break
            if next_line.startswith('use ') or next_line.startswith('pub mod'):
                line = line.replace('//!', '//', 1)
        new_lines.append(line)
    with open(path, 'w') as f:
        f.write('\n'.join(new_lines))
```

### Pattern 2: Mismatched braces (missing `    })` + `    }`)

Subagents write `fn ... { Box::pin(async move {` with only `    }` + `}` at the end, missing:
- `)` for Box::pin
- A closing `    }` for the fn block (at 4-space indent, before the impl-level `}`)

**Machine check:** Run the brace/paren trace above. Final balance should be 0.

**Fix per file:** Change ending from:
```
        TransformResult { ... }
    }
}
```
to:
```
        TransformResult { ... }
    })
    }
}
```

### Pattern 3: `async fn` → `Pin<Box<dyn Future>>` in trait

When a `Dimension` trait uses `Pin<Box<dyn Future>>` (not `async fn`), all implementations must match. The correct signature:

```rust
fn transform<'a>(&'a self, ctx: &'a mut PipelineContext) -> Pin<Box<dyn Future<Output = TransformResult> + Send + 'a>>;
```

### Pattern 4: Mass-fix across 12+ files

For systematic errors across many files, use a single `execute_code` call with `patch` from `hermes_tools`:

```python
from hermes_tools import patch

files_to_fix = ["file1.rs", "file2.rs", ...]
for f in files_to_fix:
    patch(path=f, old_string="...", new_string="...")
```

Or for structural fixes, read-write each file directly with `open()`.

### Pattern 5: Post-fix verification

After each fix batch:
```bash
cd <project> && cargo check 2>&1 | grep "^error" | wc -l
```

If error count drops significantly (e.g., 74 → 3 → 0), you're on the right track. If it stays high, run `grep -A 15 "^error"` to see the full error text.

### Pattern 6: `fn new()` closing with `})` (synchronous constructor)

The sibling's code generator applies the `Box::pin(async move { ... })` closing pattern (`})`) to **all** `fn` blocks, including synchronous constructors that don't use Box::pin:

```rust
// What the sibling writes (WRONG):
fn new(window_ms: u64, max_requests: u32) -> Self {
    Self {
        window_ms,
        max_requests,
        store: Mutex::new(HashMap::new()),
    })           // <-- `})` should be `}`
}
```

**Fix:** Replace `    })` with `    }` in the constructor body.

**Detection:** `cargo check` reports `error[E0061]: this function takes N arguments but M were supplied` — but confusingly the error points to CALLERS, not the definition. The actual issue is the extra `)` in the constructor body. The Python full-trace balance check (above) will show a single extra `)` as an unmatched `)`.

**Pitfall when fixing:** The fix `    })` → `    }` must NOT use `replace_all=true`, because `})` also appears in `fn transform` where it's correct (closing the async block + Box::pin `)`). See Pattern 8.

### Pattern 7: `mod tests` nested inside `impl` block

The sibling places `#[cfg(test)] mod tests { ... }` INSIDE `impl Dimension for X { ... }` blocks. The impl block never gets its closing `}` because the test module sits between the last method's `}` and where the impl `}` should be:

```rust
impl Dimension for RateLimitDimension {
    fn name(&self) -> &str { "rate-limit" }
    fn transform<'a>(...) { Box::pin(async move { ... }) }
    #[cfg(test)]
    mod tests { ... }   // <-- INSIDE impl, Rust sees the next `}` as closing mod tests
}                       // <-- Rust sees this as mismatched (wants to close impl but mod tests already consumed a level)
```

**Detection:** `cargo check` reports `mismatched closing delimiter: '}'` with "unclosed delimiter" pointing to the first `{` of the `impl` block.

**Fix:** Add a closing `}` for `impl` before `#[cfg(test)]`:

```rust
impl Dimension for RateLimitDimension {
    fn name(&self) -> &str { "rate-limit" }
    fn transform<'a>(...) { Box::pin(async move { ... }) }
}   // <-- close impl HERE

#[cfg(test)]
mod tests { ... }
```

**Mass fix approach:** For multiple files with this pattern, add a `}` before `#[cfg(test)]` inline:

```python
import os
for fn in os.listdir(dims_dir):
    path = os.path.join(dims_dir, fn)
    with open(path) as f:
        content = f.read()
    if '#[cfg(test)]' not in content:
        continue
    content = content.replace('#[cfg(test)]', '}\n\n#[cfg(test)]', 1)
    with open(path, 'w') as f:
        f.write(content)
```

### Pattern 8: `replace_all=true` patch corruption

When using `replace_all=true` with `old_string='    })'` and `new_string='    }'`, the change also hits legitimate `    })` in `fn transform` (which correctly closes `async { }` + Box::pin `()`):

```rust
// BEFORE — fn transform (correctly balanced):
fn transform<'a>(...) { Box::pin(async move {
    TransformResult { ... }
    })        // closes async } + Box::pin )
}}

// AFTER patch with replace_all=true (WRONG):
fn transform<'a>(...) { Box::pin(async move {
    TransformResult { ... }
    }         // closes async } ONLY — Box::pin ( is orphaned
}}
```

**Fix:** NEVER use `replace_all=true` for patterns like `    })` that appear in multiple semantic roles. Always include enough surrounding context to make the old_string unique:

```python
# WRONG — hits BOTH fn new AND fn transform:
patch(mode='replace', replace_all=True, path=file,
      old_string='    })', new_string='    }')

# RIGHT — only hits fn new because context differs:
patch(mode='replace', path=file,
      old_string='            store: Mutex::new(HashMap::new()),\n        })',
      new_string='            store: Mutex::new(HashMap::new()),\n        }')
```

**Recovery:** If `replace_all=true` already corrupted the file, read the file, identify which occurrences were wrongly modified, and fix them individually. For heavily corrupted files, rewrite from a known-good reference.

### Pattern 9: Scoped verification in multi-error workspaces

When the workspace has pre-existing errors in unrelated files, `cargo check` returns many errors that drown out your module's issues. Filter by module path:

```bash
# Zero-in on YOUR modules only:
cargo check --lib 2>&1 | grep "^  --> src/(evidence|provider)/" | sort -u

# Count errors in your modules:
cargo check --lib 2>&1 | grep -c "^  --> src/(evidence|provider)/" || echo "0 errors in target modules"
```

This lets you verify your changes are clean even when sibling subagent files are broken.

## Parallel Dispatch Strategy for Compilation Fixes

When 20+ errors remain after initial brace fixes, dispatch 3-4 subagents in parallel, each targeting an error class:

| Subagent | Target | Files |
|----------|--------|-------|
| A | E0782/E0277 (trait/future) | pipeline/mod.rs, runner.rs |
| B | E0271/E0308 (type mismatch) | handler/, correction/, dimensions/ |
| C | Missing fns/traits (default_stream_mode, From) | pipeline/mod.rs, types.rs |
| D | Send issues | llm.rs, pipeline/ |

**Verification after parallel dispatch:** Each subagent works independently. After ALL return, run `cargo check`. Most integration errors (cross-file naming drift) are caught here. The parent should also check for structural corruption (duplicate blocks from parallel edits to the same file).
