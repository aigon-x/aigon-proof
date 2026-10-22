```rust
//! Component Registry — rejestracja i wstrzykiwanie zależności dla serwisów runtime.
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Kanały danych — co serwis produkuje lub konsumuje.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DataChannel {
    KpiMetrics,
    KernelHealth,
    TickResults,
    IqScore,
    InferenceStatus,
    DecisionHistory,
    ScalerMetrics,
    CognitiveMetrics,
    TestBatteryResults,
    SystemConfig,
    MeshState,
}

impl DataChannel {
    pub fn label(&self) -> &'static str { /* ... */ }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ComponentId(pub String);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComponentRegistration {
    pub id: ComponentId,
    pub name: String,
    pub version: String,
    pub produces: Vec<DataChannel>,
    pub consumes: Vec<DataChannel>,
    pub status: ComponentStatus,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ComponentStatus {
    Registered,
    Active,
    Degraded(String),
    Failed(String),
}

pub struct ComponentRegistry {
    components: Vec<ComponentRegistration>,
    wiring: HashMap<DataChannel, Vec<ComponentId>>,    // kanał → konsumenci
    producers: HashMap<DataChannel, Vec<ComponentId>>, // kanał → producenci
}

impl ComponentRegistry {
    pub fn new() -> Self { /* ... */ }

    /// Rejestruje komponent. Nie blokuje jeśli brak providera — tylko health_report ostrzega.
    pub fn register(&mut self, comp: ComponentRegistration) -> Result<(), String> {
        for needed in &comp.consumes {
            if !self.producers.contains_key(needed) && !comp.produces.contains(needed) {
                // Warning: brak providera, ale rejestracja przechodzi
            }
        }
        for needed in &comp.consumes {
            self.wiring.entry(*needed).or_default().push(comp.id.clone());
        }
        for produced in &comp.produces {
            self.producers.entry(*produced).or_default().push(comp.id.clone());
        }
        self.components.push(comp);
        Ok(())
    }

    pub fn providers_for(&self, channel: &DataChannel) -> Vec<&ComponentId> { /* ... */ }
    pub fn consumers_for(&self, channel: &DataChannel) -> Vec<&ComponentId> { /* ... */ }

    /// Raport: które komponenty mają niespełnione zależności?
    pub fn health_report(&self) -> Vec<String> {
        let mut issues = Vec::new();
        for comp in &self.components {
            for needed in &comp.consumes {
                if self.providers_for(needed).is_empty() && !comp.produces.contains(needed) {
                    issues.push(format!("{} needs {:?} — no provider registered", comp.name, needed));
                }
            }
        }
        issues
    }
}

// ─── DataBus ─────────────────────────────────────────────

#[async_trait::async_trait]
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

// ─── Boot sequence ───────────────────────────────────────
// W Runtime::run() (Stage 5):
//   self.setup_components().await;
//   info!("[Stage 5.25] Component registry initialized");
//
// setup_components() rejestruje każdy serwis z jego DataChannel:
//   KpiCounters        → produkuje KpiMetrics
//   CognitiveEngine    → produkuje CognitiveMetrics, konsumuje TickResults
//   RuntimeIntelligence → produkuje IqScore, konsumuje KpiMetrics+KernelHealth+CognitiveMetrics
//   InferenceEngine    → produkuje InferenceStatus, konsumuje SystemConfig
//   DecisionEngine     → produkuje DecisionHistory, konsumuje KpiMetrics+KernelHealth+IqScore+InferenceStatus
//   AdaptiveScaler     → produkuje ScalerMetrics
```
