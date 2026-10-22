//! AIGON Governance — one MCP server over laws, gates and measured perfection.
//!
//! Usage:
//!   aigon-governance-mcp              # MCP over stdio
//!   aigon-governance-mcp --http 8080  # read-only web explorer + JSON API

use aigon_governance_mcp::{data, mcp, telemetry, web};
use anyhow::Result;
use rmcp::ServiceExt;

#[tokio::main]
async fn main() -> Result<()> {
    let _telemetry = telemetry::init();

    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--stats") {
        println!("{}", serde_json::to_string_pretty(&data::stats()?)?);
        return Ok(());
    }
    aigon_governance_mcp::proof::engine()?;
    tracing::info!("Operator credential file: <AIGON_PROOF_STATE or .aigon-proof>/operator.token");

    if let Some(pos) = args.iter().position(|arg| arg == "--http") {
        let port: u16 = args
            .get(pos + 1)
            .and_then(|p| p.parse().ok())
            .unwrap_or(8080);
        let public = args.iter().any(|arg| arg == "--public");
        let host = if public { [0, 0, 0, 0] } else { [127, 0, 0, 1] };
        let addr = std::net::SocketAddr::from((host, port));
        let listener = tokio::net::TcpListener::bind(addr).await?;
        tracing::info!("web explorer on http://{addr}");
        axum::serve(listener, web::router()).await?;
        return Ok(());
    }

    let service = mcp::Governance::new()
        .serve(rmcp::transport::stdio())
        .await?;
    service.waiting().await?;
    Ok(())
}
