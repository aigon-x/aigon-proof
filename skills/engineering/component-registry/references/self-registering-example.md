# SelfRegistering Trait — Concrete Example

## Pattern: Each service registers itself, not a central orchestrator

Instead of a `setup_components()` function that knows about every service,
each service defines its own `registration()` via the `SelfRegistering` trait.

## Trait definition

```rust
pub trait SelfRegistering {
    fn registration(&self) -> ComponentRegistration;
    fn register_with(&self, registry: &mut ComponentRegistry) -> Result<(), String> {
        registry.register(self.registration())
    }
}
```

## Per-service registration stubs

Each service creates a zero-sized struct that implements SelfRegistering:

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

struct DecisionService;
impl SelfRegistering for DecisionService {
    fn registration(&self) -> ComponentRegistration {
        ComponentRegistration {
            id: ComponentId("decision_engine".into()), name: "DecisionEngine".into(), version: "2.0".into(),
            produces: vec![DataChannel::DecisionHistory],
            consumes: vec![DataChannel::KpiMetrics, DataChannel::KernelHealth,
                          DataChannel::IqScore, DataChannel::InferenceStatus],
            status: ComponentStatus::Active,
        }
    }
}
```

## Boot sequence call

In the async boot function:

```rust
async fn setup_components(&self) {
    use component_registry::{SelfRegistering, ComponentRegistration, ComponentStatus, DataChannel, ComponentId};
    let mut reg = self.component_registry.lock().await;

    // Each service registers itself — no central list
    let _ = KpiService.register_with(&mut reg);
    let _ = CognitiveService.register_with(&mut reg);
    let _ = IqService.register_with(&mut reg);
    let _ = InferenceService.register_with(&mut reg);
    let _ = DecisionService.register_with(&mut reg);
    let _ = ScalerService.register_with(&mut reg);

    let issues = reg.health_report();
    if !issues.is_empty() {
        tracing::warn!("Component registry issues: {:?}", issues);
    }
}
```

## Key design decision

Registration succeeds even when providers are missing — `health_report()` surfaces
gaps as warnings instead of blocking boot. This lets services start with partial
wiring and operators see what's missing.
