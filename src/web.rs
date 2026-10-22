//! Read-only HTTP explorer used for the public demo.

use axum::extract::Request;
use axum::extract::{Path, Query};
use axum::http::header;
use axum::middleware::Next;
use axum::response::{Html, IntoResponse, Response};
use axum::routing::get;
use axum::Json;
use axum::Router;
use rmcp::transport::streamable_http_server::session::local::LocalSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use serde::Deserialize;
use std::sync::Arc;

use crate::data;

const INDEX: &str = include_str!("static/index.html");

#[derive(Clone, Default)]
pub struct AppState;

#[derive(Debug, Deserialize)]
pub struct LawQuery {
    q: Option<String>,
    limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
pub struct GateQuery {
    profile: Option<String>,
    severity: Option<String>,
}

fn ct_eq(left: &str, right: &str) -> bool {
    let (left, right) = (left.as_bytes(), right.as_bytes());
    if left.len() != right.len() {
        return false;
    }
    let mut diff = 0u8;
    for (a, b) in left.iter().zip(right) {
        diff |= a ^ b;
    }
    diff == 0
}

/// Writes and executions require `X-API-Key` whenever `AIGON_API_KEY` is set.
/// Reads stay public so a judge can explore without credentials.
async fn require_key_for_writes(request: Request, next: Next) -> Response {
    let is_write = !matches!(
        request.method(),
        &axum::http::Method::GET | &axum::http::Method::HEAD
    );
    if is_write {
        if let Ok(expected) = std::env::var("AIGON_API_KEY") {
            if !expected.is_empty() {
                let provided = request
                    .headers()
                    .get("x-api-key")
                    .and_then(|value| value.to_str().ok())
                    .unwrap_or("");
                if !ct_eq(provided, &expected) {
                    return (
                        axum::http::StatusCode::UNAUTHORIZED,
                        Json(serde_json::json!({ "error": "missing or invalid X-API-Key" })),
                    )
                        .into_response();
                }
            }
        }
    }
    next.run(request).await
}

fn host_allowed(host_header: &str) -> bool {
    if host_header.trim().is_empty() {
        return true;
    }
    let hostname = if let Some(rest) = host_header.strip_prefix('[') {
        rest.split(']').next().unwrap_or(rest)
    } else if host_header.matches(':').count() == 1 {
        host_header.split(':').next().unwrap_or(host_header)
    } else {
        host_header
    }
    .trim()
    .to_ascii_lowercase();

    if matches!(hostname.as_str(), "127.0.0.1" | "localhost" | "::1") {
        return true;
    }
    if std::env::var("AIGON_ALLOW_ANY_HOST").as_deref() == Ok("1") {
        return true;
    }
    std::env::var("AIGON_ALLOWED_HOSTS")
        .map(|hosts| {
            hosts.split(',').any(|candidate| {
                let candidate = candidate.trim().trim_matches(['[', ']']);
                candidate.eq_ignore_ascii_case(&hostname)
                    || candidate.eq_ignore_ascii_case(host_header.trim())
            })
        })
        .unwrap_or(false)
}

/// Host allowlist for the whole surface, not only `/mcp` (DNS-rebinding defence).
async fn require_allowed_host(request: Request, next: Next) -> Response {
    let host = request
        .headers()
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("");
    if !host_allowed(host) {
        return (
            axum::http::StatusCode::FORBIDDEN,
            Json(serde_json::json!({ "error": "host not allowed" })),
        )
            .into_response();
    }
    next.run(request).await
}

pub fn router() -> Router {
    let mut mcp_config = StreamableHttpServerConfig::default();
    if let Ok(hosts) = std::env::var("AIGON_ALLOWED_HOSTS") {
        let parsed: Vec<String> = hosts
            .split(',')
            .map(|host| host.trim().to_string())
            .filter(|host| !host.is_empty())
            .collect();
        if !parsed.is_empty() {
            mcp_config.allowed_hosts = parsed;
        }
    }
    let mcp_service = StreamableHttpService::new(
        || Ok(crate::mcp::Governance::new()),
        Arc::new(LocalSessionManager::default()),
        mcp_config,
    );
    Router::new()
        .route("/", get(index))
        .route("/api/health", get(health))
        .route("/api/laws", get(laws))
        .route("/api/laws/semantic", get(laws_semantic))
        .route("/api/laws/hybrid", get(laws_hybrid))
        .route("/api/laws/{id}", get(law))
        .route("/api/gates", get(gates))
        .route("/api/stats", get(stats))
        .route("/api/perfection", get(perfection))
        .route("/api/capabilities", get(capabilities))
        .route("/api/skills", get(skills))
        .route("/api/skills/categories", get(skill_categories))
        .route("/api/skills/{name}", get(skill_content))
        .route("/api/prompts", get(prompts))
        .route("/api/gates/{id}/run", axum::routing::post(run_gate))
        .route("/api/context", get(context))
        .route("/api/matrix", get(matrix))
        .route("/api/graph", get(graph))
        .route("/api/proof/catalog", get(proof_catalog))
        .route("/api/proof/parse", axum::routing::post(proof_parse))
        .route("/api/proof/operator", axum::routing::post(proof_operator))
        .route("/api/proof/approve", axum::routing::post(proof_approve))
        .route("/api/proof/execute", axum::routing::post(proof_execute))
        .route("/api/proof/receipts", get(proof_receipts))
        .route("/api/proof/deliveries/{id}", get(proof_delivery))
        .route("/api/proof/evaluate", axum::routing::post(proof_evaluate))
        .route("/api/proof/issue", axum::routing::post(proof_issue))
        .route("/api/proof/verify", axum::routing::post(proof_verify))
        .route("/api/proof/crash-tests", get(proof_crash_tests))
        .route("/proof", get(proof_page))
        .route("/api/aigon-code/status", get(aigon_code_status))
        .nest_service("/mcp", mcp_service)
        .layer(axum::middleware::from_fn(require_allowed_host))
        .layer(axum::middleware::from_fn(require_key_for_writes))
        .layer(tower_http::compression::CompressionLayer::new())
        .layer(axum::extract::DefaultBodyLimit::max(65_536))
        .with_state(AppState)
}

async fn index() -> impl IntoResponse {
    (
        [(header::CACHE_CONTROL, "no-store, max-age=0")],
        Html(INDEX),
    )
}

async fn health() -> Response {
    match data::stats() {
        Ok(stats) => {
            Json(serde_json::json!({ "ok": true, "laws": stats.laws, "gates": stats.gates }))
                .into_response()
        }
        Err(err) => (
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({ "ok": false, "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn laws(Query(query): Query<LawQuery>) -> Response {
    let limit = query.limit.unwrap_or(20).clamp(1, 200);
    let result = match query.q {
        Some(q) if !q.trim().is_empty() => data::search_laws(&q, limit),
        _ => data::laws().map(|all| all.iter().take(limit).cloned().collect()),
    };
    match result {
        Ok(items) => Json(items).into_response(),
        Err(err) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn law(Path(id): Path<String>) -> Response {
    match data::find_law(&id) {
        Ok(Some(law)) => Json(law).into_response(),
        Ok(None) => (
            axum::http::StatusCode::NOT_FOUND,
            Json(serde_json::json!({ "error": format!("law not found: {id}") })),
        )
            .into_response(),
        Err(err) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn gates(Query(query): Query<GateQuery>) -> Response {
    match data::gates() {
        Ok(all) => {
            let filtered: Vec<_> = all
                .iter()
                .filter(|gate| {
                    query
                        .profile
                        .as_ref()
                        .is_none_or(|p| gate.profiles.iter().any(|x| x == p))
                })
                .filter(|gate| {
                    query
                        .severity
                        .as_ref()
                        .is_none_or(|s| gate.severity.eq_ignore_ascii_case(s))
                })
                .collect();
            Json(filtered).into_response()
        }
        Err(err) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn stats() -> Response {
    match data::stats() {
        Ok(stats) => Json(stats).into_response(),
        Err(err) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn perfection() -> Response {
    Json(data::perfection()).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use http_body_util::BodyExt;
    use tower::util::ServiceExt;

    #[tokio::test]
    async fn index_is_served_with_no_store() {
        let response = router()
            .oneshot(Request::builder().uri("/").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers()[header::CACHE_CONTROL],
            "no-store, max-age=0"
        );
    }

    #[tokio::test]
    async fn laws_endpoint_returns_items() {
        let response = router()
            .oneshot(
                Request::builder()
                    .uri("/api/laws?limit=5")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert!(value.as_array().map(|a| !a.is_empty()).unwrap_or(false));
    }
}

#[derive(Debug, Deserialize)]
pub struct LimitQuery {
    limit: Option<usize>,
}

async fn capabilities(Query(q): Query<LimitQuery>) -> Response {
    match data::capabilities(q.limit.unwrap_or(50).clamp(1, 500)) {
        Ok(items) => Json(items).into_response(),
        Err(err) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn skills(Query(q): Query<LimitQuery>) -> Response {
    let root = data::skills_root();
    Json(data::skills(
        &root.to_string_lossy(),
        q.limit.unwrap_or(50).clamp(1, 300),
    ))
    .into_response()
}

async fn prompts(Query(q): Query<LimitQuery>) -> Response {
    let root = std::env::var("AIGON_PROMPTS").unwrap_or_else(|_| "/opt/PROD/config".to_string());
    Json(data::prompts(&root, q.limit.unwrap_or(50).clamp(1, 300))).into_response()
}

async fn run_gate(Path(id): Path<String>) -> Response {
    if std::env::var("AIGON_ALLOW_RUN").as_deref() != Ok("1") {
        return (axum::http::StatusCode::FORBIDDEN,
                Json(serde_json::json!({ "error": "gates_run disabled (set AIGON_ALLOW_RUN=1 to enable)" })))
            .into_response();
    }
    let gate = match data::find_gate(&id) {
        Ok(Some(gate)) => gate,
        Ok(None) => {
            return (
                axum::http::StatusCode::NOT_FOUND,
                Json(serde_json::json!({ "error": format!("gate not found: {id}") })),
            )
                .into_response()
        }
        Err(err) => {
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({ "error": err.to_string() })),
            )
                .into_response()
        }
    };
    match crate::runner::run_selftest(&gate.id, &gate.script).await {
        Ok(result) => Json(result).into_response(),
        Err(err) => (
            axum::http::StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn context(Query(q): Query<LimitQuery>) -> Response {
    match data::context_pack(q.limit.unwrap_or(4000)) {
        Ok(pack) => Json(pack).into_response(),
        Err(err) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn matrix() -> Response {
    match data::gate_matrix() {
        Ok(value) => Json(value).into_response(),
        Err(err) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn laws_semantic(Query(q): Query<LawQuery>) -> Response {
    let query = q.q.unwrap_or_default();
    match data::laws_semantic_search(&query, q.limit.unwrap_or(10).clamp(1, 50)) {
        Ok(hits) => Json(hits).into_response(),
        Err(err) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn laws_hybrid(Query(q): Query<LawQuery>) -> Response {
    let query = q.q.unwrap_or_default();
    match data::laws_hybrid_search(&query, q.limit.unwrap_or(10).clamp(1, 50)) {
        Ok(result) => Json(result).into_response(),
        Err(err) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn skill_content(Path(name): Path<String>) -> Response {
    match data::skill_content(&name, 20_000) {
        Ok(skill) => Json(skill).into_response(),
        Err(err) => (
            axum::http::StatusCode::NOT_FOUND,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn skill_categories() -> Json<serde_json::Value> {
    let root = data::skills_root();
    let skills = data::skills(&root.to_string_lossy(), 10_000);
    let mut counts: std::collections::BTreeMap<String, usize> = Default::default();
    for skill in &skills {
        let key = skill.category.clone().unwrap_or_else(|| "other".into());
        *counts.entry(key).or_insert(0) += 1;
    }
    Json(serde_json::json!({ "total": skills.len(), "categories": counts }))
}

async fn graph() -> Response {
    match data::graph(800) {
        Ok(value) => Json(value).into_response(),
        Err(err) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn aigon_code_status() -> Response {
    match crate::runner::aigon_code("status").await {
        Ok(result) => Json(result).into_response(),
        Err(err) => (
            axum::http::StatusCode::BAD_GATEWAY,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn proof_evaluate(Json(request): Json<crate::proof::ActionRequest>) -> Response {
    proof_result(crate::proof::evaluate(&request))
}

async fn proof_issue(Json(request): Json<crate::proof::ActionRequest>) -> Response {
    match crate::proof::issue(&request) {
        Ok(passport) => Json(passport).into_response(),
        Err(err) => (
            axum::http::StatusCode::FORBIDDEN,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

#[derive(Debug, serde::Deserialize)]
struct VerifyBody {
    passport: crate::proof::Passport,
    action: Option<crate::proof::ActionRequest>,
}

async fn proof_verify(Json(body): Json<VerifyBody>) -> Response {
    proof_result(crate::proof::verify(&body.passport, body.action.as_ref()))
}

async fn proof_crash_tests() -> Response {
    proof_result(crate::proof::crash_tests())
}

async fn proof_page() -> impl IntoResponse {
    (
        [(header::CACHE_CONTROL, "no-store, max-age=0")],
        Html(include_str!("static/proof.html")),
    )
}

fn proof_result<T: serde::Serialize>(result: anyhow::Result<T>) -> Response {
    match result {
        Ok(value) => Json(value).into_response(),
        Err(err) => (
            axum::http::StatusCode::FORBIDDEN,
            Json(serde_json::json!({"error":err.to_string()})),
        )
            .into_response(),
    }
}
fn operator_token(headers: &axum::http::HeaderMap) -> &str {
    headers
        .get("x-operator-token")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
}
async fn proof_catalog() -> Response {
    Json(serde_json::json!({"documents":crate::proof::documents(),"recipients":crate::proof::recipients(),"operations":["deliver","archive"],"executor":"local document inbox; no email or cloud transmission"})).into_response()
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CommandBody {
    command: String,
}
async fn proof_parse(Json(body): Json<CommandBody>) -> Response {
    proof_result(crate::proof::parse_command(&body.command))
}
async fn proof_operator(headers: axum::http::HeaderMap) -> Response {
    proof_result(crate::proof::engine().and_then(|e| {
        anyhow::ensure!(
            e.authenticate(operator_token(&headers)),
            "operator authentication required"
        );
        Ok(serde_json::json!({"authenticated":true}))
    }))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApprovalBody {
    action: crate::proof::ActionRequest,
    reviewed_hash: String,
    approved: bool,
}
async fn proof_approve(headers: axum::http::HeaderMap, Json(body): Json<ApprovalBody>) -> Response {
    proof_result(crate::proof::engine().and_then(|e| {
        e.approve(
            &body.action,
            &body.reviewed_hash,
            body.approved,
            operator_token(&headers),
        )
    }))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ExecuteBody {
    passport: crate::proof::Passport,
    action: crate::proof::ActionRequest,
}
async fn proof_execute(Json(body): Json<ExecuteBody>) -> Response {
    proof_result(crate::proof::engine().and_then(|e| e.execute(&body.passport, &body.action)))
}
async fn proof_receipts(headers: axum::http::HeaderMap) -> Response {
    proof_result(crate::proof::engine().and_then(|e| {
        anyhow::ensure!(
            e.authenticate(operator_token(&headers)),
            "operator authentication required"
        );
        e.receipts()
    }))
}
async fn proof_delivery(headers: axum::http::HeaderMap, Path(id): Path<String>) -> Response {
    proof_result(crate::proof::engine().and_then(|e| {
        anyhow::ensure!(
            e.authenticate(operator_token(&headers)),
            "operator authentication required"
        );
        let (receipt, content) = e.delivered(&id)?;
        Ok(serde_json::json!({"receipt":receipt,"content":content,"integrity_verified":true}))
    }))
}
