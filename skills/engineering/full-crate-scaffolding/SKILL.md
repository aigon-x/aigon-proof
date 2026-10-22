---
name: full-crate-scaffolding
description: Pattern for creating production-quality Rust crates from scratch — full implementation, comprehensive tests, zero stubs
source: auto-skill
extracted_at: '2026-05-30T05:48:10.926Z'
---


# Full Crate Scaffolding Pattern

Create complete, production-quality Rust crates from scratch with full implementations, comprehensive tests, and zero stubs/TODOs.

## Principle

Never create a stub or placeholder crate. Every new crate must be immediately compilable, testable, and usable — with full implementations, not "TODO" placeholders. A half-implemented crate is technical debt from day one.

## Workflow

```
define API → implement types → implement core logic → write tests → workspace integration → verify
```

## Phase 1 — Define the Public API

Before writing any code, define the **complete public API surface**. Every public struct, enum, trait, and function.

### Template: Cargo.toml

```toml
[package]
name = "aigon-<name>"
version.workspace = true
edition.workspace = true

[dependencies]
aigon-types = { path = "../aigon-types" }
serde.workspace = true
serde_json.workspace = true
thiserror.workspace = true
tracing.workspace = true
chrono.workspace = true

[dev-dependencies]
rand = "0.8"
tempfile = "3"
```

**Guidelines:**
- Minimize dependencies — only what the crate actually needs
- If a crate can work with `std` only, prefer that (zero extern deps = maximum portability)
- For dev-dependencies, use `tempfile` for filesystem tests, `rand` for fuzzing

### Template: lib.rs structure

```rust
//! <crate-docs> — one paragraph, what problem it solves.
//!
//! # Architecture
//!
//! <2-3 sentence architecture description>
//!
//! # Example
//!
//! ```rust
//! // working example that demonstrates core usage
//! ```

// ── Public API ──
pub use types::*;
// pub use module1::*;
// pub use module2::*;

mod types;
// mod module1;
// mod module2;
```

**Guidelines:**
- `lib.rs` is the facade — re-exports from modules, minimal code
- Each module is a separate file in `src/`
- `types.rs` contains ALL public types for the crate (easy to find)
- Each module has a specific, single responsibility

## Phase 2 — Create Core Types

Create `types.rs` with ALL enums, structs, and type aliases the crate needs:

### Template: types.rs

```rust
/// <purpose> — one line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum CoreEnum {
    Variant1,
    Variant2,
    /// <specific description for this variant>
    Variant3,
}

impl CoreEnum {
    pub fn description(&self) -> &'static str {
        match self {
            Self::Variant1 => "Human-readable description",
            Self::Variant2 => "Another description",
            Self::Variant3 => "And another",
        }
    }
}

/// <purpose> — with all fields documented.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CoreStruct {
    /// <field purpose>
    pub field1: TypeA,
    /// <field purpose>
    pub field2: Vec<TypeB>,
}

impl CoreStruct {
    pub fn new(field1: TypeA) -> Self {
        Self { field1, field2: Vec::new() }
    }
}
```

**Guidelines:**
- Every variant and field MUST have a doc comment
- Use `#[derive(Debug, Clone, ...)]` — everything should be clonable/debuggable
- Implement `new()` constructors with sensible defaults
- Keep types clean — no methods that do I/O in types.rs (those go in their module)

## Phase 3 — Implement Core Logic

Create module files for each logical component. Each module must be a **complete implementation** with:

### Algorithm implementation rules:

1. **No stubs** — `todo!()` or `unimplemented!()` or `unreachable!()` are FORBIDDEN
2. **No TODOs** — `// TODO` comments are FORBIDDEN in committed code
3. **No mock-only implementations** — every function must do real work
4. **Edge cases handled** — empty inputs, zero values, max values, concurrent access
5. **Error types** — use `thiserror` with meaningful variants, not `String` errors

### Example: Kademlia DHT routing table

```rust
impl KBucket {
    pub fn upsert(&mut self, info: PeerInfo, now: Instant) {
        // Find existing entry
        if let Some(pos) = self.entries.iter().position(|e| e.matches(&info.id)) {
            self.entries[pos].mark_alive(now);
            return;
        }
        // Bucket full?
        if self.entries.len() >= self.max_size {
            // LRU eviction: demote oldest alive → suspect,
            // or replace oldest suspect
            self.evict_one(now);
        }
        self.entries.push(RoutingTableEntry::Alive(info));
    }

    fn evict_one(&mut self, now: Instant) {
        // Strategy: demote oldest alive to suspect
        if let Some(pos) = self.entries.iter().position(|e| e.is_alive()) {
            if let RoutingTableEntry::Alive(info) = &self.entries[pos] {
                self.entries[pos] = RoutingTableEntry::Suspect(info.clone(), 1);
            }
            return;
        }
        // Remove oldest dead/suspect
        self.entries.retain(|e| !matches!(e, RoutingTableEntry::Dead(_)));
        if self.entries.len() >= self.max_size {
            self.entries.remove(0);
        }
    }
}
```

## Phase 4 — Complete Type Integration

For complex protocols (Raft, Kademlia, STUN), implement the **data model and protocol logic** together:

### Message/Protocol pattern:

```rust
pub enum Message {
    Ping(PeerId),
    Pong(PeerId),
    FindNode { target: PeerId, sender: PeerId },
    Nodes(Vec<PeerInfo>),
}

pub struct Protocol {
    pub routing_table: RoutingTable,
}

impl Protocol {
    pub fn handle_message(&mut self, msg: Message, sender: PeerId) -> Option<Message> {
        match msg {
            Message::Ping(from) => {
                self.routing_table.mark_alive(&from);
                Some(Message::Pong(self.routing_table.local_id))
            }
            Message::FindNode { target, sender } => {
                self.routing_table.mark_alive(&sender);
                let nodes = self.routing_table.find_node(&target);
                Some(Message::Nodes(nodes))
            }
            // ... etc
        }
    }
}
```

**For Raft**, implement ALL safety properties:

```rust
impl RaftNode {
    /// Check election restriction: candidate must have at least as up-to-date log
    fn can_vote_for(&self, candidate_last_index: u64, candidate_last_term: u64) -> bool {
        let (my_last_index, my_last_term) = self.last_log_term_index();
        candidate_last_term > my_last_term
            || (candidate_last_term == my_last_term && candidate_last_index >= my_last_index)
    }

    /// Log matching safety: follower must have prev_log_index/term matching
    fn check_log_match(&self, prev_log_index: u64, prev_log_term: u64) -> bool {
        if prev_log_index == 0 { return true; }
        self.log.get(prev_log_index as usize - 1)
            .map(|e| e.term == prev_log_term)
            .unwrap_or(false)
    }
}
```

**For STUN/NAT**, implement RFC-based binary parsing:

```rust
impl StunMessage {
    pub fn parse(data: &[u8]) -> Result<Self, NatError> {
        if data.len() < 20 { return Err(NatError::Truncated); }
        let msg_type = u16::from_be_bytes([data[0], data[1]]);
        let length = u16::from_be_bytes([data[2], data[3]]) as usize;
        let transaction_id = data[8..20].try_into().unwrap();
        // Parse attributes
        let mut offset = 20;
        let mut attributes = Vec::new();
        while offset + 4 <= data.len() {
            let attr_type = u16::from_be_bytes([data[offset], data[offset + 1]]);
            let attr_len = u16::from_be_bytes([data[offset + 2], data[offset + 3]]) as usize;
            // ... parse attribute body
        }
        // ...
    }
}
```

## Phase 5 — Write Comprehensive Tests

Every crate needs tests that verify:
1. **Core functionality** — does the main algorithm work?
2. **Edge cases** — empty inputs, zero values, max sizes, concurrent access
3. **Safety properties** — for consensus: no split-brain, no data loss
4. **Failure modes** — what happens when things go wrong?

### Test density guidelines:

| Crate Complexity | Minimum Tests | Example |
|-----------------|--------------|---------|
| Types only (enums, wrappers) | 5-10 | aigon-types, aigon-canonical |
| Single algorithm | 15-25 | aigon-p2p (Kademlia), aigon-nat (STUN) |
| State machine + protocol | 20-35 | aigon-consensus (Multi-Raft) |
| Pipeline + parallelism | 10-20 | aigon-swarm, aigon-pipeline |

### Test patterns:

```rust
#[test]
fn test_basic_operation() {
    let mut table = RoutingTable::new(PeerId::generate());
    let peer = PeerInfo { id: PeerId::generate(), ... };
    table.insert(peer.clone());
    assert_eq!(table.peer_count(), 1);
}

#[test]
fn test_node_churn() {
    let mut table = RoutingTable::new(PeerId::generate());
    // Add 30 peers (k=20, some will be evicted)
    for _ in 0..30 {
        table.insert(PeerInfo { id: PeerId::generate(), ... });
    }
    // Verify max is bounded by config + 2× k for margin
    assert!(table.peer_count() <= 60, "Churn causes unbounded growth");
}

#[test]
fn test_partition_majority_continues() {
    let mut leader = RaftNode::new(config, NodeId::new(1), peers.clone());
    let mut follower = RaftNode::new(config, NodeId::new(2), peers.clone());
    // ... simulate partition with messages
}

#[test]
fn test_stun_parse_roundtrip() {
    let msg = StunMessage::new_binding_request();
    let bytes = msg.encode();
    let parsed = StunMessage::parse(&bytes).unwrap();
    assert_eq!(msg.transaction_id, parsed.transaction_id);
}
```

### Test naming convention:

```
test_<scenario> — describes what's being tested
Examples: test_single_node_election, test_partition_heal_log_catchup,
          test_candidate_pair_sorting, test_nat_classification
```

## Phase 6 — Workspace Integration

Add the new crate to the workspace:

```toml
# In root Cargo.toml
[workspace]
members = [
    # ...
    "crates/aigon-new-crate",
]
```

Then verify:

```bash
cargo check -p aigon-new-crate
cargo test -p aigon-new-crate
```

## Phase 7 — Integrate with Runtime (if needed)

If the crate needs to be part of the runtime binary:

1. Add it as a dependency in `aigon-runtime/Cargo.toml`
2. Add it as a re-export in `aigon-runtime/src/lib.rs`
3. If it provides a service, add initialization in `AigonX::new()`

## Source-level patterns by crate type:

### Pure algorithm crate (aigon-p2p):
- No external deps beyond aigon-types + std
- Use `std::arch::x86_64` intrinsics for performance where appropriate
- Inline hex encoding if no `hex` crate dependency desired
- `/dev/urandom` for random ID generation (pure std, no getrandom dep)

### State machine crate (aigon-consensus):
- Tick-driven design: `tick()` handles timeouts, `step(msg)` handles messages
- Full Raft safety: election restriction, log matching, leader completeness
- Multi-Raft: hash-based shard routing with independent progress
- Test partition scenarios: majority continues, minority frozen, heal catches up

### Protocol parser crate (aigon-nat):
- Binary format parsing with explicit bounds checks
- RFC compliance: attribute TLV parsing, transaction IDs, magic cookies
- ICE candidate pairing: RFC 8445 priority formula
- Relay selection: score-based (capacity - load penalty)
