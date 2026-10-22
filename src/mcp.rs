//! MCP surface: seven read-only tools over the canon.

use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ContentBlock, Implementation, ServerCapabilities};
use rmcp::{tool, tool_handler, tool_router, ErrorData as McpError, ServerHandler};
use schemars::JsonSchema;
use serde::Deserialize;

use crate::data;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct LimitArgs {
    /// Maximum number of items to return (1–200).
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    20
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SearchArgs {
    pub query: String,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct IdArgs {
    /// Canonical identifier, e.g. "LAW-Ω1" or "GATE-148".
    pub id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct BudgetArgs {
    /// Character budget for the packed context (400–32 000).
    pub budget: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct JsonArgs {
    /// JSON object describing the action (actor, operation, document_id, recipient_id, approval_id).
    pub json: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct VerifyArgs {
    /// JSON object of the passport to verify.
    pub passport_json: String,
    /// Optional JSON object of the action being executed; when present the passport must match it.
    pub request_json: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GateFilter {
    /// Profile filter: L0, L1, L2 or L3.
    pub profile: Option<String>,
    /// Severity filter: BLOCKING or WARNING.
    pub severity: Option<String>,
}

#[derive(Clone)]
pub struct Governance {
    // kept so the macro-generated router stays owned by the server instance
    #[allow(dead_code)]
    tool_router: rmcp::handler::server::tool::ToolRouter<Self>,
}

fn text(value: serde_json::Value) -> Result<CallToolResult, McpError> {
    let block =
        ContentBlock::json(value).map_err(|e| McpError::internal_error(e.to_string(), None))?;
    Ok(CallToolResult::success(vec![block]))
}

fn fail<E: std::fmt::Display>(error: E) -> McpError {
    McpError::internal_error(error.to_string(), None)
}

#[tool_router]
impl Governance {
    pub fn new() -> Self {
        Self {
            tool_router: Self::tool_router(),
        }
    }

    #[tool(description = "List constitution laws with id, title, weight and layer")]
    async fn laws_list(
        &self,
        Parameters(args): Parameters<LimitArgs>,
    ) -> Result<CallToolResult, McpError> {
        let limit = args.limit.clamp(1, 200);
        let laws = data::laws().map_err(fail)?;
        text(serde_json::json!(laws
            .iter()
            .take(limit)
            .collect::<Vec<_>>()))
    }

    #[tool(description = "Return one law with its full statement")]
    async fn laws_get(
        &self,
        Parameters(args): Parameters<IdArgs>,
    ) -> Result<CallToolResult, McpError> {
        match data::find_law(&args.id).map_err(fail)? {
            Some(law) => text(serde_json::json!(law)),
            None => text(serde_json::json!({ "error": format!("law not found: {}", args.id) })),
        }
    }

    #[tool(description = "Full-text search across law ids, titles and statements")]
    async fn laws_search(
        &self,
        Parameters(args): Parameters<SearchArgs>,
    ) -> Result<CallToolResult, McpError> {
        let hits = data::search_laws(&args.query, args.limit.clamp(1, 50)).map_err(fail)?;
        text(serde_json::json!(hits))
    }

    #[tool(description = "List gates, optionally filtered by profile or severity")]
    async fn gates_list(
        &self,
        Parameters(args): Parameters<GateFilter>,
    ) -> Result<CallToolResult, McpError> {
        let gates = data::gates().map_err(fail)?;
        let filtered: Vec<_> = gates
            .iter()
            .filter(|gate| {
                args.profile
                    .as_ref()
                    .is_none_or(|p| gate.profiles.iter().any(|x| x == p))
            })
            .filter(|gate| {
                args.severity
                    .as_ref()
                    .is_none_or(|s| gate.severity.eq_ignore_ascii_case(s))
            })
            .collect();
        text(serde_json::json!(filtered))
    }

    #[tool(description = "Return one gate definition with script path, severity and profiles")]
    async fn gates_get(
        &self,
        Parameters(args): Parameters<IdArgs>,
    ) -> Result<CallToolResult, McpError> {
        match data::find_gate(&args.id).map_err(fail)? {
            Some(gate) => text(serde_json::json!(gate)),
            None => text(serde_json::json!({ "error": format!("gate not found: {}", args.id) })),
        }
    }

    #[tool(description = "Counts by law weight and gate severity")]
    async fn constitution_stats(&self) -> Result<CallToolResult, McpError> {
        text(serde_json::json!(data::stats().map_err(fail)?))
    }

    #[tool(description = "Latest measured perfection score per project")]
    async fn perfection_report(&self) -> Result<CallToolResult, McpError> {
        text(serde_json::json!(data::perfection()))
    }

    #[tool(
        description = "Classify every gate: completeness score 0-100, category and issues found"
    )]
    async fn gates_classify(&self) -> Result<CallToolResult, McpError> {
        text(serde_json::json!(data::classify_gates().map_err(fail)?))
    }

    #[tool(description = "List runtime capabilities from the canonical manifest")]
    async fn capabilities_list(
        &self,
        Parameters(args): Parameters<LimitArgs>,
    ) -> Result<CallToolResult, McpError> {
        let items = data::capabilities(args.limit.clamp(1, 500)).map_err(fail)?;
        text(serde_json::json!(items))
    }

    #[tool(
        description = "List skill packages (name, path, sha256, description) without leaking prompt bodies"
    )]
    async fn skills_list(
        &self,
        Parameters(args): Parameters<LimitArgs>,
    ) -> Result<CallToolResult, McpError> {
        let root =
            std::env::var("AIGON_SKILLS").unwrap_or_else(|_| "/srv/aigon/skills".to_string());
        text(serde_json::json!(data::skills(
            &root,
            args.limit.clamp(1, 300)
        )))
    }

    #[tool(description = "List prompt documents that shape agent behaviour, with sha256 identity")]
    async fn prompts_list(
        &self,
        Parameters(args): Parameters<LimitArgs>,
    ) -> Result<CallToolResult, McpError> {
        let root =
            std::env::var("AIGON_PROMPTS").unwrap_or_else(|_| "/srv/aigon/config".to_string());
        text(serde_json::json!(data::prompts(
            &root,
            args.limit.clamp(1, 300)
        )))
    }

    #[tool(
        description = "Run a gate's own --selftest inside an allowlist, 20 s timeout, output tail"
    )]
    async fn gates_run(
        &self,
        Parameters(args): Parameters<IdArgs>,
    ) -> Result<CallToolResult, McpError> {
        if std::env::var("AIGON_ALLOW_RUN").as_deref() != Ok("1") {
            return Err(fail("gates_run disabled (set AIGON_ALLOW_RUN=1 to enable)"));
        }
        let gate = data::find_gate(&args.id).map_err(fail)?;
        let Some(gate) = gate else {
            return text(serde_json::json!({ "error": format!("gate not found: {}", args.id) }));
        };
        let result = crate::runner::run_selftest(&gate.id, &gate.script)
            .await
            .map_err(fail)?;
        text(serde_json::json!(result))
    }

    #[tool(description = "Budgeted digest of the whole canon: laws and gates in one compact text")]
    async fn context_pack(
        &self,
        Parameters(args): Parameters<BudgetArgs>,
    ) -> Result<CallToolResult, McpError> {
        text(serde_json::json!(data::context_pack(
            args.budget.unwrap_or(4000)
        )
        .map_err(fail)?))
    }

    #[tool(description = "Gate coverage matrix across categories with average completeness")]
    async fn gate_matrix(&self) -> Result<CallToolResult, McpError> {
        text(data::gate_matrix().map_err(fail)?)
    }

    #[tool(
        description = "Rank laws by TF-IDF cosine similarity (offline lexical vectors, no model)"
    )]
    async fn laws_semantic_search(
        &self,
        Parameters(args): Parameters<SearchArgs>,
    ) -> Result<CallToolResult, McpError> {
        let hits =
            data::laws_semantic_search(&args.query, args.limit.clamp(1, 50)).map_err(fail)?;
        text(serde_json::json!(hits))
    }

    #[tool(
        description = "Swarm query: laws (vector), gates (name match) and skills (name match) gathered in parallel"
    )]
    async fn swarm_query(
        &self,
        Parameters(args): Parameters<SearchArgs>,
    ) -> Result<CallToolResult, McpError> {
        let limit = args.limit.clamp(1, 30);
        let query = args.query.clone();
        let (laws_hits, gates_hits, skills_hits) = tokio::join!(
            tokio::task::spawn_blocking(move || data::laws_hybrid_search(&query, limit)),
            async {
                let q = args.query.to_lowercase();
                data::gates().map(|all| {
                    all.iter()
                        .filter(|gate| {
                            gate.id.to_lowercase().contains(&q)
                                || gate.module.to_lowercase().contains(&q)
                        })
                        .take(limit)
                        .cloned()
                        .collect::<Vec<_>>()
                })
            },
            async {
                let root = std::env::var("AIGON_SKILLS")
                    .unwrap_or_else(|_| "/srv/aigon/skills".to_string());
                let q = args.query.to_lowercase();
                data::skills(&root, 300)
                    .into_iter()
                    .filter(|skill| {
                        skill.name.to_lowercase().contains(&q)
                            || skill.description.to_lowercase().contains(&q)
                    })
                    .take(limit)
                    .collect::<Vec<_>>()
            }
        );
        let laws_hits = laws_hits.map_err(|e| fail(e.to_string()))?.map_err(fail)?;
        let gates_hits = gates_hits.map_err(fail)?;
        text(serde_json::json!({
            "query": args.query,
            "layers": {"laws": laws_hits.hits, "laws_mode": laws_hits.mode, "gates": gates_hits, "skills": skills_hits},
            "note": "laws ranked by hybrid TF-IDF + embeddings; gates and skills by name/description match"
        }))
    }

    #[tool(
        description = "Hybrid law search: TF-IDF plus local neural embeddings, fused and ranked"
    )]
    async fn laws_hybrid_search(
        &self,
        Parameters(args): Parameters<SearchArgs>,
    ) -> Result<CallToolResult, McpError> {
        text(serde_json::json!(data::laws_hybrid_search(
            &args.query,
            args.limit.clamp(1, 50)
        )
        .map_err(fail)?))
    }

    #[tool(
        description = "Return the full SKILL.md text of one skill, hash-verified against the index"
    )]
    async fn skills_get(
        &self,
        Parameters(args): Parameters<IdArgs>,
    ) -> Result<CallToolResult, McpError> {
        text(serde_json::json!(
            data::skill_content(&args.id, 20_000).map_err(fail)?
        ))
    }

    #[tool(description = "List skills grouped by category with counts")]
    async fn skills_by_category(&self) -> Result<CallToolResult, McpError> {
        let root =
            std::env::var("AIGON_SKILLS").unwrap_or_else(|_| "/srv/aigon/skills".to_string());
        let skills = data::skills(&root, 10_000);
        let mut counts: std::collections::BTreeMap<String, usize> = Default::default();
        for skill in &skills {
            let key = skill.category.clone().unwrap_or_else(|| "other".into());
            *counts.entry(key).or_insert(0) += 1;
        }
        text(serde_json::json!({ "total": skills.len(), "categories": counts }))
    }

    #[tool(
        description = "Knowledge graph: laws, gates, skill categories and capability backends with edges"
    )]
    async fn knowledge_graph(&self) -> Result<CallToolResult, McpError> {
        text(serde_json::json!(data::graph(800).map_err(fail)?))
    }

    #[tool(
        description = "Server-owned document and recipient catalog. The executor writes real local inbox files."
    )]
    async fn proof_catalog(&self) -> Result<CallToolResult, McpError> {
        text(
            serde_json::json!({"documents":crate::proof::documents(),"recipients":crate::proof::recipients()}),
        )
    }
    #[tool(
        description = "Parse explicit command: deliver <document-id> to <recipient-id>, or archive <document-id> to records. Never infers consent."
    )]
    async fn proof_parse(
        &self,
        Parameters(args): Parameters<SearchArgs>,
    ) -> Result<CallToolResult, McpError> {
        text(serde_json::json!(
            crate::proof::parse_command(&args.query).map_err(fail)?
        ))
    }
    #[tool(
        description = "Execute approved action once. JSON: passport and action. Receipt follows durable write and hash verification. Approvals come separately from authenticated operator UI."
    )]
    async fn proof_execute(
        &self,
        Parameters(args): Parameters<JsonArgs>,
    ) -> Result<CallToolResult, McpError> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Body {
            passport: crate::proof::Passport,
            action: crate::proof::ActionRequest,
        }
        let body: Body = serde_json::from_str(&args.json).map_err(fail)?;
        text(serde_json::json!(crate::proof::engine()
            .map_err(fail)?
            .execute(&body.passport, &body.action)
            .map_err(fail)?))
    }

    #[tool(
        description = "AIGON PROOF: evaluate an action against the deterministic policy engine (ALLOW/REVIEW/BLOCK)"
    )]
    async fn proof_evaluate(
        &self,
        Parameters(args): Parameters<JsonArgs>,
    ) -> Result<CallToolResult, McpError> {
        let request: crate::proof::ActionRequest = serde_json::from_str(&args.json)
            .map_err(|e| fail(format!("invalid action JSON: {e}")))?;
        text(serde_json::json!(
            crate::proof::evaluate(&request).map_err(fail)?
        ))
    }

    #[tool(
        description = "Issue a signed action passport for an allowed action, bound to its exact parameters"
    )]
    async fn proof_issue(
        &self,
        Parameters(args): Parameters<JsonArgs>,
    ) -> Result<CallToolResult, McpError> {
        let request: crate::proof::ActionRequest = serde_json::from_str(&args.json)
            .map_err(|e| fail(format!("invalid action JSON: {e}")))?;
        text(serde_json::json!(
            crate::proof::issue(&request).map_err(fail)?
        ))
    }

    #[tool(description = "Verify a passport: signature, action binding, freshness and replay")]
    async fn proof_verify(
        &self,
        Parameters(args): Parameters<VerifyArgs>,
    ) -> Result<CallToolResult, McpError> {
        let passport: crate::proof::Passport = serde_json::from_str(&args.passport_json)
            .map_err(|e| fail(format!("invalid passport JSON: {e}")))?;
        let request = match args.request_json.as_deref() {
            Some(raw) if !raw.trim().is_empty() => Some(
                serde_json::from_str::<crate::proof::ActionRequest>(raw)
                    .map_err(|e| fail(format!("invalid action JSON: {e}")))?,
            ),
            _ => None,
        };
        text(serde_json::json!(crate::proof::verify(
            &passport,
            request.as_ref()
        )
        .map_err(fail)?))
    }

    #[tool(
        description = "Run six read-only policy probes: egress, forged approval, unknown resources and missing consent"
    )]
    async fn proof_crash_tests(&self) -> Result<CallToolResult, McpError> {
        text(serde_json::json!(crate::proof::crash_tests().map_err(fail)?))
    }

    #[tool(description = "Read-only aigon-code status through the local CLI (allowlisted command)")]
    async fn aigon_code_status(&self) -> Result<CallToolResult, McpError> {
        text(serde_json::json!(crate::runner::aigon_code("status")
            .await
            .map_err(fail)?))
    }
}

#[tool_handler]
impl ServerHandler for Governance {
    fn get_info(&self) -> rmcp::model::InitializeResult {
        rmcp::model::InitializeResult::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("aigon-governance", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "AIGON Governance exposes the constitution, the gate catalogue and measured perfection. \
                 Read-only except the explicitly allowlisted gate selftest.",
            )
    }
}

impl Default for Governance {
    fn default() -> Self {
        Self::new()
    }
}
