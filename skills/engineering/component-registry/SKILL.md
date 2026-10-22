---
name: component-registry
description: >-
  Three-layer Component Registry pattern for Rust services: registration,
  dependency resolution, and data bus pub/sub. Each service declares what
  it produces and consumes; a central registry validates wiring and a
  DataBus pushes data to consumers.
tags: [architecture, registry, wiring, dependency-injection, data-bus, rust]
---


# Component Registry Pattern

## When to use
Many services need data from other components but currently hardcode dependencies. Use this pattern when you need:
- A central registry of who-exists and who-needs-what
- Automatic validation that every data consumer has a provider
- A push-based DataBus for publishing data to registered consumers

## Three layers

```
Layer 1: ComponentRegistry    — who exists, what they produce/consume
Layer 2: DependencyResolver   — built into registry, validates wiring
Layer 3: DataBus              — publish/subscribe data distribution
```

## Step by step

### 1. Define DataChannel enum
Each channel = a type of data a service can produce or consume:
```rust
pub enum DataChannel {
    KpiMetrics, KernelHealth, TickResults, IqScore,
    InferenceStatus, DecisionHistory, ScalerMetrics, ...
}
```

### 2. Define ComponentRegistration
```rust
pub struct ComponentRegistration {
    pub id: ComponentId,
    pub name: String,
    pub version: String,
    pub produces: Vec<DataChannel>,
    pub consumes: Vec<DataChannel>,
    pub status: ComponentStatus,
}
```

### 3. ComponentRegistry::register()
Adds the component, tracks producers/consumers per channel.
Do NOT block registration when a provider is missing — just warn in `health_report()`
so the service starts but the operator can see the gap.

### 4. ComponentRegistry::health_report()
Scans all registered components, lists any `consumes` channel with zero providers.
Returns `Vec<String>` of issues — show during boot or expose in /health.

### 5. DataBus + DataConsumer trait
```rust
#[async_trait]
pub trait DataConsumer: Send + Sync {
    fn channel(&self) -> DataChannel;
    async fn on_data(&self, data: serde_json::Value);
}
```
Services subscribe by implementing DataConsumer and calling `DataBus::subscribe()`.
Publish data with `DataBus::publish(channel, json)` — all consumers receive it.

### 6. SelfRegistering trait — services register themselves
Instead of a central orchestrator that knows about every service, each service
implements `SelfRegistering` and registers itself:

```rust
pub trait SelfRegistering {
    fn registration(&self) -> ComponentRegistration;
    fn register_with(&self, registry: &mut ComponentRegistry) -> Result<(), String> {
        registry.register(self.registration())
    }
}
```

Each service defines its own `registration()` — no central list:

```rust
struct KpiService;
impl SelfRegistering for KpiService {
    fn registration(&self) -> ComponentRegistration {
        ComponentRegistration {
            id: ComponentId("kpi".into()), name: "KpiCounters".into(), version: "2.0".into(),
            produces: vec![DataChannel::KpiMetrics], consumes: vec![],
            status: ComponentStatus::Active,
        }
    }
}
// In boot: KpiService.register_with(&mut registry)?;
```

### 7. Boot-time wiring
In the runtime's boot sequence, call `setup_components()` which registers every service
with its channels (via `register_with`), then logs any health issues.

## Pitfalls
- `blocking_lock()` inside a tokio runtime panics — use `.lock().await` (async Mutex). This is caught at runtime as a panic in `main`, not a compile error.
- Don't reject registration for missing providers — services can start without full wiring, just warn
- Keep DataBus channels coarse (not per-field) — KpiMetrics contains all KPI counters
- The same component can both produce and consume the same channel (self-wiring)
- Use `file_path: 'component_registry.rs'` (not `kpi.rs` or similar) so the module name in `lib.rs` is `pub mod component_registry;` — the convention is `snake_case` matching the file name
- `setup_components()` must be async and called with `.await` — if called synchronously inside a tokio `#[main]`, the `blocking_lock()` panic fires immediately

## DataBus implementation

The DataBus lives in the same file as ComponentRegistry. Key parts:

```rust
#[async_trait]
pub trait DataConsumer: Send + Sync {
    fn channel(&self) -> DataChannel;
    async fn on_data(&self, data: serde_json::Value);
}

pub struct DataBus {
    consumers: HashMap<DataChannel, Vec<Box<dyn DataConsumer>>>,
}

impl DataBus {
    pub fn subscribe(&mut self, consumer: Box<dyn DataConsumer>) {
        let channel = consumer.channel();
        self.consumers.entry(channel).or_default().push(consumer);
    }
    pub async fn publish(&self, channel: DataChannel, data: serde_json::Value) {
        if let Some(consumers) = self.consumers.get(&channel) {
            for consumer in consumers {
                consumer.on_data(data.clone()).await;
            }
        }
    }
}
```

Consumers register in the boot sequence (not in tick). Publishing happens in tick from whatever component produces the data.

## Reference files
- `references/self-registering-example.md` — concrete SelfRegistering trait usage per service
- `references/data-bus-implementation.md` — full DataBus + ComponentRegistry implementation with boot-sequence wiring

## Verification
- Unit tests: register valid component, check consumers_for/providers_for, health_report
- Integration: DataBus publishes, DataConsumer receives
- Boot log: `[Stage 5.25] Component registry initialized`
