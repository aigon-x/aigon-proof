# DataBus Implementation — Full Reference

## File structure

The DataBus lives alongside ComponentRegistry in a single `component_registry.rs` module.
The module is declared in `lib.rs` as `pub mod component_registry;`.

## Complete implementation

```rust
//! Component Registry — registration and dependency injection for runtime services.
//!
//! Each component registers: what it produces, what it consumes.
//! DependencyResolver checks if all consumers have providers.
//! DataBus pushes data to all registered consumers of a channel.

use std::collections::HashMap;
use std::sync::Arc;

/// Registered component descriptor.
#[derive(Debug, Clone)]
pub struct ComponentRegistration {
    pub id: ComponentId,
    pub name: String,
    pub version: String,
    pub produces: Vec<DataChannel>,
    pub consumes: Vec<DataChannel>,
    pub status: ComponentStatus,
}

#[derive(Debug, Clone, Hash, Eq, PartialEq)]
pub struct ComponentId(pub String);

#[derive(Debug, Clone)]
pub enum ComponentStatus { Active, Registered, Degraded, Failed }

/// Data channels — coarse-grained data types published via DataBus.
#[derive(Debug, Clone, Copy, Hash, Eq, PartialEq)]
pub enum DataChannel {
    KpiMetrics, KernelHealth, TickResults, IqScore, TestBatteryResults,
    InferenceStatus, DecisionHistory, ScalerMetrics, CognitiveMetrics,
    SystemConfig, MeshState,
}

impl std::fmt::Display for DataChannel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self)
    }
}

/// Trait: services register themselves instead of a central orchestrator.
pub trait SelfRegistering {
    fn registration(&self) -> ComponentRegistration;
    fn register_with(&self, registry: &mut ComponentRegistry) -> Result<(), String> {
        registry.register(self.registration())
    }
}

/// ComponentRegistry — who exists, what they produce/consume.
/// Does NOT block registration for missing providers — just warns.
#[derive(Debug)]
pub struct ComponentRegistry {
    components: Vec<ComponentRegistration>,
    producers: HashMap<DataChannel, Vec<ComponentId>>,
    consumers: HashMap<DataChannel, Vec<ComponentId>>,
}

impl ComponentRegistry {
    pub fn new() -> Self {
        Self { components: Vec::new(), producers: HashMap::new(), consumers: HashMap::new() }
    }

    pub fn register(&mut self, comp: ComponentRegistration) -> Result<(), String> {
        // Reject duplicate IDs
        if self.components.iter().any(|c| c.id == comp.id) {
            return Err(format!("Component '{}' already registered", comp.id.0));
        }
        // Register what this component produces
        for ch in &comp.produces {
            self.producers.entry(*ch).or_default().push(comp.id.clone());
        }
        // Register what this component consumes
        for ch in &comp.consumes {
            self.consumers.entry(*ch).or_default().push(comp.id.clone());
        }
        self.components.push(comp);
        Ok(())
    }

    pub fn providers_for(&self, channel: &DataChannel) -> Vec<&ComponentId> {
        self.producers.get(channel).map(|v| v.iter().collect()).unwrap_or_default()
    }

    pub fn consumers_for(&self, channel: &DataChannel) -> Vec<&ComponentId> {
        self.consumers.get(channel).map(|v| v.iter().collect()).unwrap_or_default()
    }

    pub fn health_report(&self) -> Vec<String> {
        let mut issues = Vec::new();
        for comp in &self.components {
            for needed in &comp.consumes {
                let providers = self.providers_for(needed);
                if providers.is_empty() && !comp.produces.contains(needed) {
                    issues.push(format!("{} needs {:?} — no provider registered", comp.name, needed));
                }
            }
        }
        issues
    }

    pub fn all(&self) -> &[ComponentRegistration] { &self.components }
}

/// DataBus — push data to all consumers of a channel.
#[async_trait::async_trait]
pub trait DataConsumer: Send + Sync {
    fn channel(&self) -> DataChannel;
    async fn on_data(&self, data: serde_json::Value);
}

pub struct DataBus {
    consumers: HashMap<DataChannel, Vec<Box<dyn DataConsumer>>>,
}

impl DataBus {
    pub fn new() -> Self { Self { consumers: HashMap::new() } }

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

## Usage in boot sequence

```rust
// In Runtime::new() or a setup_components() method:
async fn setup_components(&self) {
    use component_registry::{
        SelfRegistering, ComponentRegistration,
        ComponentStatus, DataChannel, ComponentId,
    };
    let mut reg = self.component_registry.lock().await;

    struct KpiService;
    impl SelfRegistering for KpiService {
        fn registration(&self) -> ComponentRegistration {
            ComponentRegistration {
                id: ComponentId("kpi".into()),
                name: "KpiCounters".into(),
                version: "2.0".into(),
                produces: vec![DataChannel::KpiMetrics],
                consumes: vec![],
                status: ComponentStatus::Active,
            }
        }
    }
    struct DecisionService;
    impl SelfRegistering for DecisionService {
        fn registration(&self) -> ComponentRegistration {
            ComponentRegistration {
                id: ComponentId("decision_engine".into()),
                name: "DecisionEngine".into(),
                version: "2.0".into(),
                produces: vec![DataChannel::DecisionHistory],
                consumes: vec![DataChannel::KpiMetrics, DataChannel::KernelHealth],
                status: ComponentStatus::Active,
            }
        }
    }

    let _ = KpiService.register_with(&mut reg);
    let _ = DecisionService.register_with(&mut reg);
    // ... etc

    let issues = reg.health_report();
    if !issues.is_empty() {
        tracing::warn!("Component registry issues: {:?}", issues);
    }
}
```

## Key design decisions

1. **Registration never blocks.** Missing providers are warnings, not errors — services start with partial wiring.
2. **Coarse channels.** `KpiMetrics` contains all KPI counters (not per-counter channels).
3. **Self-registering services.** Each service defines its own `registration()` via `SelfRegistering` trait — no central list.
4. **DataBus is push-based.** Publishers call `publish()`, consumers implement `on_data()`.
5. **Async Mutex is mandatory.** `blocking_lock()` inside a tokio runtime panics at runtime.
6. **Boot sequence stage.** Component registry initializes at Stage 5.25 (after scheduler, before fabric init).
