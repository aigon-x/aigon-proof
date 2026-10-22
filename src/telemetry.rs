//! OpenTelemetry wiring. Traces are exported over OTLP/HTTP when
//! `OTEL_EXPORTER_OTLP_ENDPOINT` is set; otherwise the server runs with local logs only.

use opentelemetry::trace::TracerProvider as _;
use opentelemetry::KeyValue;
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::trace::SdkTracerProvider;
use opentelemetry_sdk::Resource;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

fn endpoint() -> Option<String> {
    std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT").ok()
}

fn provider_for(base: &str) -> Option<SdkTracerProvider> {
    let exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_http()
        .with_endpoint(format!("{}/v1/traces", base.trim_end_matches('/')))
        .build()
        .ok()?;
    Some(
        SdkTracerProvider::builder()
            .with_batch_exporter(exporter)
            .with_resource(
                Resource::builder()
                    .with_service_name("aigon-governance")
                    .with_attributes([KeyValue::new("deployment.environment", "hackathon")])
                    .build(),
            )
            .build(),
    )
}

pub fn init() -> Option<SdkTracerProvider> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let base = endpoint();

    if let Some(base) = base {
        if let Some(provider) = provider_for(&base) {
            let tracer = provider.tracer("aigon-governance");
            let layer = tracing_opentelemetry::layer().with_tracer(tracer);
            if tracing_subscriber::registry()
                .with(filter)
                .with(layer)
                .try_init()
                .is_ok()
            {
                tracing::info!(endpoint = %base, "OTLP trace export enabled");
                return Some(provider);
            }
        }
    }

    let _ = tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .try_init();
    None
}
