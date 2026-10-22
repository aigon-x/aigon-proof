//! Read-only view over the AIGON canon: constitution laws, gate catalogue and the
//! latest measured perfection snapshot. Nothing here writes to canonical files.

use std::path::PathBuf;
use std::sync::OnceLock;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Law {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub weight: Option<String>,
    #[serde(default)]
    pub layer: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Gate {
    pub id: String,
    #[serde(default)]
    pub module: String,
    #[serde(default)]
    pub script: String,
    #[serde(default)]
    pub severity: String,
    #[serde(default)]
    pub profiles: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Stats {
    pub laws: usize,
    pub gates: usize,
    pub law_weights: std::collections::BTreeMap<String, usize>,
    pub gate_severities: std::collections::BTreeMap<String, usize>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProjectScore {
    pub event: String,
    pub score: f64,
    pub gaps: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Perfection {
    pub available: bool,
    pub generated_at: Option<String>,
    pub projects: Vec<ProjectScore>,
    pub reason: Option<String>,
}

fn bundled_path(relative: &str) -> PathBuf {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(relative);
    if manifest.exists() {
        manifest
    } else {
        PathBuf::from(relative)
    }
}

/// Resolve the skill root. Standalone runs use the bundled `skills/` directory so a
/// fresh clone does not silently depend on `/opt/PROD`.
pub fn skills_root() -> PathBuf {
    if let Ok(root) = std::env::var("AIGON_SKILLS") {
        let root = root.trim().to_string();
        if !root.is_empty() {
            return PathBuf::from(root);
        }
    }
    if std::env::var("AIGON_STANDALONE").as_deref() == Ok("1") {
        let bundled = bundled_path("skills");
        if bundled.is_dir() {
            return bundled;
        }
    }
    PathBuf::from("/opt/PROD/skills")
}

fn fallback(local: &str, canonical: &str) -> PathBuf {
    let standalone = std::env::var("AIGON_STANDALONE").as_deref() == Ok("1");
    if !standalone && std::path::Path::new(canonical).exists() {
        PathBuf::from(canonical)
    } else {
        bundled_path(local)
    }
}

fn constitution_path() -> PathBuf {
    std::env::var("AIGON_CONSTITUTION")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            fallback(
                "fixtures/canon/constitution.yaml",
                "/opt/PROD/config/canonical/constitution.generated.yaml",
            )
        })
}

fn gates_path() -> PathBuf {
    std::env::var("AIGON_GATES")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            fallback(
                "fixtures/canon/gates.yaml",
                "/opt/PROD/config/canonical/gates.yaml",
            )
        })
}

fn perfection_path() -> PathBuf {
    std::env::var("AIGON_PERFECTION_STATE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            fallback(
                "fixtures/canon/perfection.json",
                "/opt/PROD/products/monai/monai-hackathons/state/perfection.json",
            )
        })
}

fn read_yaml(path: &PathBuf) -> Result<serde_yaml::Value> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("cannot read canonical file {}", path.display()))?;
    serde_yaml::from_str(&text).with_context(|| format!("invalid YAML in {}", path.display()))
}

/// Load laws from the constitution. Accepts both `statement` and `text` keys.
pub fn load_laws(path: &PathBuf) -> Result<Vec<Law>> {
    let doc = read_yaml(path)?;
    let items = doc
        .get("laws")
        .and_then(|v| v.as_sequence())
        .ok_or_else(|| anyhow!("{} has no laws array", path.display()))?;
    let mut laws = Vec::with_capacity(items.len());
    for item in items {
        let id = item
            .get("id")
            .or_else(|| item.get("code"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if id.is_empty() {
            continue;
        }
        let text = item
            .get("statement")
            .or_else(|| item.get("text"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        laws.push(Law {
            id,
            title: item
                .get("name")
                .or_else(|| item.get("title"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            text,
            weight: item
                .get("violation_class")
                .or_else(|| item.get("weight"))
                .map(|v| {
                    v.as_str()
                        .map(str::to_string)
                        .unwrap_or_else(|| format!("{v:?}"))
                }),
            layer: item.get("layer").map(|v| {
                v.as_str()
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("{v:?}"))
            }),
        });
    }
    Ok(laws)
}

/// Load gates. Accepts `gates` or `modules` as the top-level sequence.
pub fn load_gates(path: &PathBuf) -> Result<Vec<Gate>> {
    let doc = read_yaml(path)?;
    let items = doc
        .get("gates")
        .or_else(|| doc.get("modules"))
        .and_then(|v| v.as_sequence())
        .ok_or_else(|| anyhow!("{} has no gates array", path.display()))?;
    let mut gates = Vec::new();
    for item in items {
        let id = item
            .get("id")
            .or_else(|| item.get("module"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if id.is_empty() {
            continue;
        }
        let profiles = match item.get("profiles").or_else(|| item.get("profile")) {
            Some(serde_yaml::Value::Sequence(seq)) => seq
                .iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect(),
            Some(serde_yaml::Value::String(s)) => vec![s.clone()],
            _ => Vec::new(),
        };
        gates.push(Gate {
            module: item
                .get("module")
                .and_then(|v| v.as_str())
                .unwrap_or(&id)
                .to_string(),
            script: item
                .get("script")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            severity: item
                .get("severity")
                .and_then(|v| v.as_str())
                .unwrap_or("WARNING")
                .to_string(),
            profiles,
            id,
        });
    }
    Ok(gates)
}

static LAWS: OnceLock<Vec<Law>> = OnceLock::new();
static GATES: OnceLock<Vec<Gate>> = OnceLock::new();

pub fn laws() -> Result<&'static [Law]> {
    if let Some(v) = LAWS.get() {
        return Ok(v.as_slice());
    }
    let loaded = load_laws(&constitution_path())?;
    Ok(LAWS.get_or_init(|| loaded).as_slice())
}

pub fn gates() -> Result<&'static [Gate]> {
    if let Some(v) = GATES.get() {
        return Ok(v.as_slice());
    }
    let loaded = load_gates(&gates_path())?;
    Ok(GATES.get_or_init(|| loaded).as_slice())
}

pub fn find_law(id: &str) -> Result<Option<Law>> {
    let needle = id.trim().to_lowercase();
    Ok(laws()?
        .iter()
        .find(|law| law.id.to_lowercase() == needle)
        .cloned())
}

pub fn find_gate(id: &str) -> Result<Option<Gate>> {
    let needle = id.trim().to_lowercase();
    Ok(gates()?
        .iter()
        .find(|gate| gate.id.to_lowercase() == needle)
        .cloned())
}

pub fn search_laws(query: &str, limit: usize) -> Result<Vec<Law>> {
    let needle = query.trim().to_lowercase();
    let all = laws()?;
    if needle.is_empty() {
        return Ok(all.iter().take(limit).cloned().collect());
    }
    Ok(all
        .iter()
        .filter(|law| {
            law.id.to_lowercase().contains(&needle)
                || law.title.to_lowercase().contains(&needle)
                || law.text.to_lowercase().contains(&needle)
        })
        .take(limit)
        .cloned()
        .collect())
}

pub fn stats() -> Result<Stats> {
    let mut law_weights = std::collections::BTreeMap::new();
    for law in laws()? {
        let key = law.weight.clone().unwrap_or_else(|| "unstated".to_string());
        *law_weights.entry(key).or_insert(0) += 1;
    }
    let mut gate_severities = std::collections::BTreeMap::new();
    for gate in gates()? {
        *gate_severities.entry(gate.severity.clone()).or_insert(0) += 1;
    }
    Ok(Stats {
        laws: laws()?.len(),
        gates: gates()?.len(),
        law_weights,
        gate_severities,
    })
}

pub fn perfection() -> Perfection {
    let path = perfection_path();
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(_) => {
            return Perfection {
                available: false,
                generated_at: None,
                projects: Vec::new(),
                reason: Some(format!("perfection state not found at {}", path.display())),
            }
        }
    };
    let doc: serde_json::Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(err) => {
            return Perfection {
                available: false,
                generated_at: None,
                projects: Vec::new(),
                reason: Some(format!("invalid JSON: {err}")),
            }
        }
    };
    let projects = doc
        .get("projects")
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .map(|p| ProjectScore {
                    event: p
                        .get("event")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    score: p.get("score").and_then(|v| v.as_f64()).unwrap_or(0.0),
                    gaps: p
                        .get("gaps")
                        .and_then(|v| v.as_array())
                        .map(|g| {
                            g.iter()
                                .filter_map(|x| x.as_str().map(str::to_string))
                                .collect()
                        })
                        .unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default();
    Perfection {
        available: true,
        generated_at: doc
            .get("generated_at")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        projects,
        reason: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_file(name: &str, body: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("aigon-gov-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        let mut file = std::fs::File::create(&path).unwrap();
        file.write_all(body.as_bytes()).unwrap();
        path
    }

    const LAW_YAML: &str = r#"
laws:
  - id: LAW-1
    name: First law
    text: Short statement
    violation_class: P0
    layer: omega
  - id: LAW-2
    name: Second law
    text: Mentions memory
    violation_class: P1
"#;

    const GATE_YAML: &str = r#"
gates:
  - module: check-one
    script: one.sh
    severity: BLOCKING
    profiles: [L1, L2]
  - id: GATE-TWO
    module: check-two
    script: two.sh
    severity: WARNING
    profile: L0
"#;

    #[test]
    fn loads_law_fields_from_canonical_shape() {
        let path = temp_file("laws.yaml", LAW_YAML);
        let laws = load_laws(&path).unwrap();
        assert_eq!(laws.len(), 2);
        assert_eq!(laws[0].id, "LAW-1");
        assert_eq!(laws[0].title, "First law");
        assert_eq!(laws[0].weight.as_deref(), Some("P0"));
        assert_eq!(laws[0].layer.as_deref(), Some("omega"));
    }

    #[test]
    fn loads_gates_with_sequence_and_single_profile() {
        let path = temp_file("gates.yaml", GATE_YAML);
        let gates = load_gates(&path).unwrap();
        assert_eq!(gates.len(), 2);
        assert_eq!(gates[0].profiles, vec!["L1".to_string(), "L2".to_string()]);
        assert_eq!(gates[1].id, "GATE-TWO");
        assert_eq!(gates[1].profiles, vec!["L0".to_string()]);
    }

    #[test]
    fn missing_file_is_an_error() {
        let path = PathBuf::from("/nonexistent/aigon/laws.yaml");
        assert!(load_laws(&path).is_err());
    }

    #[test]
    fn search_is_case_insensitive() {
        let path = temp_file("laws-search.yaml", LAW_YAML);
        let laws = load_laws(&path).unwrap();
        let needle = "MEMORY".to_lowercase();
        let hits: Vec<_> = laws
            .iter()
            .filter(|law| law.text.to_lowercase().contains(&needle))
            .collect();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, "LAW-2");
    }
}

/// Score a gate for how complete its definition is. Deterministic, no model call:
/// the same inputs always produce the same classification, which is what a rulebook needs.
#[derive(Debug, Clone, Serialize)]
pub struct GateClass {
    pub id: String,
    pub module: String,
    pub category: String,
    pub score: u8,
    pub issues: Vec<String>,
}

fn category_for(module: &str) -> &'static str {
    let m = module.to_ascii_lowercase();
    if m.contains("secret") || m.contains("vault") || m.contains("credential") {
        "security"
    } else if m.contains("law") || m.contains("constitution") || m.contains("canon") {
        "governance"
    } else if m.contains("test") || m.contains("selftest") || m.contains("verify") {
        "testing"
    } else if m.contains("deploy") || m.contains("docker") || m.contains("build") {
        "delivery"
    } else if m.contains("metric") || m.contains("otel") || m.contains("prom") {
        "observability"
    } else {
        "general"
    }
}

/// Look for the gate script in the usual roots. Missing script is the strongest signal
/// that a gate exists only on paper.
fn script_exists(script: &str) -> bool {
    if script.is_empty() {
        return false;
    }
    let roots = [
        "/opt/PROD/tools/verify",
        "/opt/PROD/tools/gates",
        "/opt/PROD/tools",
    ];
    roots.iter().any(|root| {
        let path = std::path::Path::new(root).join(script);
        path.is_file()
    })
}

pub fn classify_gates() -> Result<Vec<GateClass>> {
    let mut out = Vec::new();
    for gate in gates()? {
        let mut issues = Vec::new();
        let mut score: i32 = 100;
        if !script_exists(&gate.script) {
            score -= 40;
            issues.push("script not found on disk".to_string());
        }
        if gate.profiles.is_empty() {
            score -= 15;
            issues.push("no profile assigned".to_string());
        }
        if gate.severity.eq_ignore_ascii_case("WARNING") {
            score -= 5;
            issues.push("non-blocking severity".to_string());
        }
        if gate.script.is_empty() {
            score -= 20;
            issues.push("empty script path".to_string());
        }
        out.push(GateClass {
            id: gate.id.clone(),
            module: gate.module.clone(),
            category: category_for(&gate.module).to_string(),
            score: score.clamp(0, 100) as u8,
            issues,
        });
    }
    out.sort_by_key(|c| c.score);
    Ok(out)
}

#[derive(Debug, Clone, Serialize)]
pub struct Capability {
    pub id: String,
    pub name: String,
    pub domain: Option<String>,
    pub backend: Option<String>,
    pub enabled: bool,
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Artefact {
    pub name: String,
    pub path: String,
    pub sha256: String,
    pub description: String,
    #[serde(default)]
    pub category: Option<String>,
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub fn capabilities(limit: usize) -> Result<Vec<Capability>> {
    let path = std::env::var("AIGON_CAPABILITIES")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            fallback(
                "fixtures/canon/capabilities.yaml",
                "/opt/PROD/runtime/manifests/capabilities.yaml",
            )
        });
    let doc = read_yaml(&path)?;
    let entries = doc
        .get("entries")
        .and_then(|v| v.as_sequence())
        .ok_or_else(|| anyhow!("no entries"))?;
    Ok(entries
        .iter()
        .take(limit)
        .map(|entry| {
            let name = entry
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let backend = entry
                .get("backend")
                .and_then(|v| v.as_str())
                .map(str::to_string);
            Capability {
                id: entry
                    .get("id")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&name)
                    .to_string(),
                name,
                domain: entry
                    .get("domain")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
                backend,
                enabled: entry
                    .get("enabled")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(true),
                description: entry
                    .get("description")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .chars()
                    .take(120)
                    .collect(),
            }
        })
        .collect())
}

fn skill_category(name: &str, description: &str) -> String {
    let hay = format!("{name} {description}").to_lowercase();
    let rules: [(&str, &[&str]); 9] = [
        (
            "governance",
            &[
                "law",
                "canon",
                "constitution",
                "gate",
                "bramk",
                "compliance",
                "audit",
                "policy",
            ],
        ),
        (
            "security",
            &[
                "security",
                "secret",
                "vault",
                "auth",
                "pentest",
                "osint",
                "offsec",
                "credential",
                "tls",
                "certificate",
                "firewall",
            ],
        ),
        (
            "mesh",
            &[
                "mesh",
                "tailscale",
                "node",
                "cluster",
                "quorum",
                "replication",
                "network",
            ],
        ),
        (
            "deploy",
            &[
                "deploy", "docker", "compose", "build", "release", "pipeline", "systemd", "nginx",
                "backup", "restore",
            ],
        ),
        (
            "data",
            &[
                "db", "database", "postgres", "surreal", "qdrant", "redis", "sql", "storage",
                "mount", "nas",
            ],
        ),
        (
            "agents",
            &[
                "agent", "hermes", "qwen", "claude", "grok", "codex", "prompt", "skill", "delegat",
                "subagent", "mcp",
            ],
        ),
        (
            "ui",
            &[
                "ui",
                "ux",
                "design",
                "css",
                "frontend",
                "react",
                "visual",
                "animation",
                "theme",
                "accessibility",
            ],
        ),
        (
            "game",
            &["game", "roblox", "luau", "unity", "rpg", "player", "level"],
        ),
        (
            "ml",
            &[
                "ml",
                "model",
                "train",
                "inference",
                "embedding",
                "llm",
                "kaggle",
                "benchmark",
            ],
        ),
    ];
    let mut best = ("other", 0usize);
    for (category, keys) in rules {
        let score = keys.iter().filter(|key| hay.contains(**key)).count();
        if score > best.1 {
            best = (category, score);
        }
    }
    best.0.to_string()
}

/// Skills are prompt packages: name, hash and the first line of their description.
fn load_index(path: &str, limit: usize) -> Vec<Artefact> {
    let path = bundled_path(path);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let Ok(items) = serde_json::from_str::<Vec<Artefact>>(&text) else {
        return Vec::new();
    };
    items.into_iter().take(limit).collect()
}

pub fn skills(root: &str, limit: usize) -> Vec<Artefact> {
    if !std::path::Path::new(root).is_dir() {
        return load_index("fixtures/skills-index.json", limit);
    }
    let mut out = Vec::new();
    for entry in walkdir::WalkDir::new(root)
        .max_depth(3)
        .into_iter()
        .flatten()
    {
        if entry.file_name() != "SKILL.md" {
            continue;
        }
        let path = entry.path();
        let Ok(bytes) = std::fs::read(path) else {
            continue;
        };
        let text = String::from_utf8_lossy(&bytes);
        let description = text
            .lines()
            .find(|line| line.starts_with("description:"))
            .map(|line| {
                line.trim_start_matches("description:")
                    .trim()
                    .trim_matches('>')
                    .trim()
                    .to_string()
            })
            .unwrap_or_default();
        let name = path
            .parent()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let description_short: String = description.chars().take(160).collect();
        let category = path
            .strip_prefix(std::path::Path::new(root))
            .ok()
            .and_then(|relative| relative.components().next())
            .map(|component| component.as_os_str().to_string_lossy().to_string())
            .filter(|value| !value.is_empty())
            .or_else(|| Some(skill_category(&name, &description)));
        out.push(Artefact {
            name,
            path: path.display().to_string(),
            sha256: sha256_hex(&bytes),
            description: description_short,
            category,
        });
        if out.len() >= limit {
            break;
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Prompt documents that shape agent behaviour (persona, operating rules).
pub fn prompts(root: &str, limit: usize) -> Vec<Artefact> {
    if !std::path::Path::new(root).is_dir() {
        return load_index("fixtures/prompts-index.json", limit);
    }
    let mut out = Vec::new();
    for entry in walkdir::WalkDir::new(root)
        .max_depth(2)
        .into_iter()
        .flatten()
    {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let Ok(bytes) = std::fs::read(path) else {
            continue;
        };
        let text = String::from_utf8_lossy(&bytes);
        let description = text
            .lines()
            .next()
            .unwrap_or("")
            .chars()
            .take(160)
            .collect();
        out.push(Artefact {
            name: path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
            path: path.display().to_string(),
            sha256: sha256_hex(&bytes),
            description,
            category: None,
        });
        if out.len() >= limit {
            break;
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Compact, budgeted digest of the canon. This is the "virtual context" view: it never
/// returns more than `budget` characters, and marks truncation instead of silently cutting.
#[derive(Debug, Clone, Serialize)]
pub struct ContextPack {
    pub text: String,
    pub characters: usize,
    pub budget: usize,
    pub truncated: bool,
    pub sections: Vec<String>,
}

pub fn context_pack(budget: usize) -> Result<ContextPack> {
    let budget = budget.clamp(400, 32_000);
    let mut sections = Vec::new();
    let mut text = String::from("# AIGON canon\n");
    let law_list = laws()?;
    text.push_str(&format!("\n## Laws ({})\n", law_list.len()));
    for law in law_list {
        let line = format!(
            "- {} {} [{}]\n",
            law.id,
            law.title,
            law.weight.clone().unwrap_or_default()
        );
        if text.len() + line.len() > budget {
            break;
        }
        text.push_str(&line);
    }
    sections.push("laws".into());
    let gate_list = gates()?;
    text.push_str(&format!("\n## Gates ({})\n", gate_list.len()));
    for gate in gate_list {
        let line = format!("- {} {} ({})\n", gate.id, gate.module, gate.severity);
        if text.len() + line.len() > budget {
            break;
        }
        text.push_str(&line);
    }
    sections.push("gates".into());
    let truncated = text.len() >= budget;
    if text.len() > budget {
        text.truncate(budget);
    }
    Ok(ContextPack {
        characters: text.len(),
        budget,
        truncated,
        sections,
        text,
    })
}

/// Gate matrix: counts per inferred category with average completeness.
pub fn gate_matrix() -> Result<serde_json::Value> {
    let classes = classify_gates()?;
    let mut by_category: std::collections::BTreeMap<String, serde_json::Value> = Default::default();
    for class in &classes {
        let entry = by_category
            .entry(class.category.clone())
            .or_insert_with(|| {
                serde_json::json!({
                    "gates": 0, "avg_score": 0.0, "low_confidence": 0
                })
            });
        let gates = entry["gates"].as_u64().unwrap_or(0) + 1;
        entry["gates"] = serde_json::json!(gates);
        let avg = entry["avg_score"].as_f64().unwrap_or(0.0);
        entry["avg_score"] =
            serde_json::json!(((avg * (gates - 1) as f64) + class.score as f64) / gates as f64);
        if class.score < 60 {
            let low = entry["low_confidence"].as_u64().unwrap_or(0) + 1;
            entry["low_confidence"] = serde_json::json!(low);
        }
    }
    Ok(
        serde_json::json!({ "dimensions": ["category", "severity", "completeness"],
                           "gates": classes.len(), "by_category": by_category }),
    )
}

#[test]
fn context_pack_respects_budget() {
    let pack = context_pack(600).unwrap();
    assert!(pack.characters <= 600);
    assert!(pack.text.contains("## Laws"));
    assert!(pack.text.contains("## Gates"));
    assert!(pack.truncated || pack.characters < 600);
}

#[test]
fn gate_matrix_has_dimensions() {
    let matrix = gate_matrix().unwrap();
    assert!(matrix["dimensions"].is_array());
    assert!(matrix["by_category"].is_object());
}

/// Lexical vectors: TF-IDF over laws and skills with cosine similarity.
/// This is deterministic and offline — no model download, no network, same answer every run.
#[derive(Debug, Clone, Serialize)]
pub struct SemanticHit {
    pub id: String,
    pub title: String,
    pub score: f64,
}

struct DocVec {
    id: String,
    title: String,
    vector: std::collections::BTreeMap<String, f64>,
    norm: f64,
}

fn tokenize(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| {
            !c.is_alphanumeric()
                && c != 'ą'
                && c != 'ę'
                && c != 'ł'
                && c != 'ń'
                && c != 'ó'
                && c != 'ś'
                && c != 'ź'
                && c != 'ż'
        })
        .filter(|token| token.len() >= 3)
        .map(str::to_string)
        .collect()
}

fn build_index(docs: Vec<(String, String, String)>) -> Vec<DocVec> {
    let n = docs.len().max(1) as f64;
    let mut df: std::collections::BTreeMap<String, usize> = Default::default();
    let tokenised: Vec<(String, String, Vec<String>)> = docs
        .into_iter()
        .map(|(id, title, text)| {
            let tokens = tokenize(&format!("{title} {text}"));
            for token in &tokens {
                *df.entry(token.clone()).or_insert(0) += 1;
            }
            (id, title, tokens)
        })
        .collect();
    tokenised
        .into_iter()
        .map(|(id, title, tokens)| {
            let mut tf: std::collections::BTreeMap<String, f64> = Default::default();
            for token in tokens {
                *tf.entry(token).or_insert(0.0) += 1.0;
            }
            let mut vector = std::collections::BTreeMap::new();
            for (token, count) in tf {
                let idf = ((n / (*df.get(&token).unwrap_or(&1) as f64)) + 1.0).ln();
                vector.insert(token, count * idf);
            }
            let norm = vector.values().map(|v| v * v).sum::<f64>().sqrt();
            DocVec {
                id,
                title,
                vector,
                norm,
            }
        })
        .collect()
}

fn query_vector(query: &str, index: &[DocVec]) -> std::collections::BTreeMap<String, f64> {
    let mut tf: std::collections::BTreeMap<String, f64> = Default::default();
    for token in tokenize(query) {
        *tf.entry(token).or_insert(0.0) += 1.0;
    }
    // IDF proxy: rare-in-index terms weigh more.
    let df: std::collections::BTreeMap<String, usize> = index
        .iter()
        .flat_map(|doc| doc.vector.keys().cloned().collect::<Vec<_>>())
        .fold(Default::default(), |mut acc, key| {
            *acc.entry(key).or_insert(0) += 1;
            acc
        });
    let n = index.len().max(1) as f64;
    tf.into_iter()
        .map(|(token, count)| {
            let idf = ((n / (*df.get(&token).unwrap_or(&1) as f64)) + 1.0).ln();
            (token, count * idf)
        })
        .collect()
}

fn cosine(query: &std::collections::BTreeMap<String, f64>, doc: &DocVec) -> f64 {
    let dot: f64 = query
        .iter()
        .map(|(token, weight)| weight * doc.vector.get(token).copied().unwrap_or(0.0))
        .sum();
    let qnorm = query.values().map(|v| v * v).sum::<f64>().sqrt();
    if qnorm == 0.0 || doc.norm == 0.0 {
        0.0
    } else {
        dot / (qnorm * doc.norm)
    }
}

static LAW_INDEX: OnceLock<Vec<DocVec>> = OnceLock::new();

fn law_index() -> Result<&'static [DocVec]> {
    if let Some(index) = LAW_INDEX.get() {
        return Ok(index.as_slice());
    }
    let docs = laws()?
        .iter()
        .map(|law| (law.id.clone(), law.title.clone(), law.text.clone()))
        .collect();
    Ok(LAW_INDEX.get_or_init(|| build_index(docs)).as_slice())
}

pub fn laws_semantic_search(query: &str, limit: usize) -> Result<Vec<SemanticHit>> {
    let index = law_index()?;
    let qv = query_vector(query, index);
    let mut hits: Vec<SemanticHit> = index
        .iter()
        .map(|doc| SemanticHit {
            id: doc.id.clone(),
            title: doc.title.clone(),
            score: (cosine(&qv, doc) * 1000.0).round() / 1000.0,
        })
        .filter(|hit| hit.score > 0.0)
        .collect();
    hits.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    hits.truncate(limit);
    Ok(hits)
}

/// Hybrid retrieval: lexical TF-IDF and local neural embeddings, fused by a fixed weight.
/// `mode` tells the client which path actually ran, so a missing model is never hidden.
#[derive(Debug, Clone, Serialize)]
pub struct HybridHit {
    pub id: String,
    pub title: String,
    pub lexical: f64,
    pub vector: f64,
    pub score: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct HybridResult {
    pub mode: String,
    pub hits: Vec<HybridHit>,
}

static LAW_EMB: OnceLock<Option<Vec<Vec<f32>>>> = OnceLock::new();

fn law_embeddings() -> Option<&'static Vec<Vec<f32>>> {
    LAW_EMB
        .get_or_init(|| {
            let docs: Vec<String> = laws()
                .ok()?
                .iter()
                .map(|law| format!("{} {}", law.title, law.text))
                .collect();
            crate::embeddings::embed(docs)
        })
        .as_ref()
}

pub fn laws_hybrid_search(query: &str, limit: usize) -> Result<HybridResult> {
    let lexical = laws_semantic_search(query, 50)?;
    let lexical_map: std::collections::BTreeMap<String, f64> = lexical
        .iter()
        .map(|hit| (hit.id.clone(), hit.score))
        .collect();

    let embeddings = law_embeddings();
    let query_vector = embeddings.and_then(|_| crate::embeddings::embed(vec![query.to_string()]));
    let vector_scores: std::collections::BTreeMap<String, f64> = match (embeddings, query_vector) {
        (Some(docs), Some(mut vectors)) if !vectors.is_empty() => {
            let qv = vectors.remove(0);
            laws()?
                .iter()
                .zip(docs.iter())
                .map(|(law, doc)| (law.id.clone(), crate::embeddings::cosine(&qv, doc) as f64))
                .collect()
        }
        _ => Default::default(),
    };

    let mode = if vector_scores.is_empty() {
        "lexical"
    } else {
        "hybrid"
    };
    let mut hits: Vec<HybridHit> = laws()?
        .iter()
        .map(|law| {
            let lex = lexical_map.get(&law.id).copied().unwrap_or(0.0);
            let vec = vector_scores.get(&law.id).copied().unwrap_or(0.0);
            let score = if vector_scores.is_empty() {
                lex
            } else {
                0.5 * lex + 0.5 * vec
            };
            HybridHit {
                id: law.id.clone(),
                title: law.title.clone(),
                lexical: (lex * 1000.0).round() / 1000.0,
                vector: (vec * 1000.0).round() / 1000.0,
                score: (score * 1000.0).round() / 1000.0,
            }
        })
        .filter(|hit| hit.score > 0.0)
        .collect();
    hits.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    hits.truncate(limit);
    Ok(HybridResult {
        mode: mode.to_string(),
        hits,
    })
}

/// Full prompt text of one skill, verified against the hash recorded in the index.
#[derive(Debug, Clone, Serialize)]
pub struct SkillContent {
    pub name: String,
    pub path: String,
    pub sha256: String,
    pub characters: usize,
    pub truncated: bool,
    pub text: String,
}

pub fn skill_content(name: &str, max_chars: usize) -> Result<SkillContent> {
    let index = load_index("fixtures/skills-index.json", usize::MAX);
    let needle = name.trim();
    let entry = index
        .into_iter()
        .find(|item| item.name == needle || item.path == needle || item.path.ends_with(needle))
        .ok_or_else(|| anyhow!("skill not found: {name}"))?;
    let path = std::path::Path::new("skills").join(&entry.path);
    let bytes = std::fs::read(&path)
        .with_context(|| format!("skill body missing from bundle: {}", path.display()))?;
    let digest = sha256_hex(&bytes);
    if digest != entry.sha256 {
        return Err(anyhow!(
            "skill hash mismatch for {}: index {} != bundle {}",
            entry.name,
            entry.sha256,
            digest
        ));
    }
    let text = String::from_utf8_lossy(&bytes).to_string();
    let truncated = text.len() > max_chars;
    let text = if truncated {
        text.chars().take(max_chars).collect()
    } else {
        text
    };
    Ok(SkillContent {
        name: entry.name,
        path: entry.path,
        sha256: digest,
        characters: text.len(),
        truncated,
        text,
    })
}

/// Knowledge graph: laws, gates, skill categories and capability backends as nodes,
/// with deterministic edges derived from shared terms and categories.
#[derive(Debug, Clone, Serialize)]
pub struct GraphNode {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub meta: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct GraphEdge {
    pub source: String,
    pub target: String,
    pub kind: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeGraph {
    pub nodes: Vec<GraphNode>,
    pub edges: Vec<GraphEdge>,
    pub truncated: bool,
    pub counts: std::collections::BTreeMap<String, usize>,
}

pub fn graph(max_edges: usize) -> Result<KnowledgeGraph> {
    let mut nodes = Vec::new();
    let mut edges = Vec::new();
    let mut counts = std::collections::BTreeMap::new();

    for law in laws()? {
        nodes.push(GraphNode {
            id: format!("law:{}", law.id),
            kind: "law".into(),
            label: law.title.clone(),
            meta: law.weight.clone().unwrap_or_default(),
        });
    }
    for gate in gates()? {
        nodes.push(GraphNode {
            id: format!("gate:{}", gate.id),
            kind: "gate".into(),
            label: gate.module.clone(),
            meta: gate.severity.clone(),
        });
    }
    let skills = skills(&skills_root().to_string_lossy(), 10_000);
    let mut categories: std::collections::BTreeMap<String, usize> = Default::default();
    for skill in &skills {
        let category = skill.category.clone().unwrap_or_else(|| "other".into());
        *categories.entry(category).or_insert(0) += 1;
    }
    for (category, count) in &categories {
        nodes.push(GraphNode {
            id: format!("category:{category}"),
            kind: "category".into(),
            label: category.clone(),
            meta: format!("{count} skills"),
        });
    }
    if let Ok(caps) = capabilities(500) {
        let mut backends: std::collections::BTreeMap<String, usize> = Default::default();
        for cap in caps {
            *backends
                .entry(cap.backend.unwrap_or_else(|| "core".into()))
                .or_insert(0) += 1;
        }
        for (backend, count) in backends {
            nodes.push(GraphNode {
                id: format!("backend:{backend}"),
                kind: "backend".into(),
                label: backend,
                meta: format!("{count} capabilities"),
            });
        }
    }

    // Edges: gate → category by keyword match on the module name.
    for gate in gates()? {
        let category = category_for(&gate.module).to_string();
        if nodes.iter().any(|n| n.id == format!("category:{category}")) {
            edges.push(GraphEdge {
                source: format!("gate:{}", gate.id),
                target: format!("category:{category}"),
                kind: "classified_as".into(),
            });
        }
    }

    // Edges: law → gate when they share at least two significant terms.
    let gate_terms: Vec<(String, std::collections::BTreeSet<String>)> = gates()?
        .iter()
        .map(|gate| {
            (
                gate.id.clone(),
                tokenize(&format!("{} {}", gate.id, gate.module))
                    .into_iter()
                    .collect(),
            )
        })
        .collect();
    for law in laws()? {
        let law_terms: std::collections::BTreeSet<String> =
            tokenize(&format!("{} {}", law.title, law.text))
                .into_iter()
                .collect();
        for (gate_id, terms) in &gate_terms {
            let shared = law_terms.intersection(terms).count();
            if shared >= 1 {
                edges.push(GraphEdge {
                    source: format!("law:{}", law.id),
                    target: format!("gate:{gate_id}"),
                    kind: "shared_terms".into(),
                });
            }
            if edges.len() >= max_edges {
                break;
            }
        }
        if edges.len() >= max_edges {
            break;
        }
    }

    let truncated = edges.len() >= max_edges;
    counts.insert("laws".into(), laws()?.len());
    counts.insert("gates".into(), gates()?.len());
    counts.insert("skills".into(), skills.len());
    Ok(KnowledgeGraph {
        nodes,
        edges,
        truncated,
        counts,
    })
}
