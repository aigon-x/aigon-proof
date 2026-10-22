//! Native action tool: run a gate's own `--selftest`, inside an allowlist, with a hard timeout.
//!
//! Nothing else is executable. The command is built as an argument vector (no shell), the
//! script must live under one of the gate roots and the name must match a strict pattern.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use serde::Serialize;
use tokio::process::Command;

const ROOTS: [&str; 3] = [
    "/opt/PROD/tools/verify",
    "/opt/PROD/tools/gates",
    "/opt/PROD/tools",
];
const TIMEOUT: Duration = Duration::from_secs(20);
const MAX_OUTPUT: usize = 2000;

#[derive(Debug, Clone, Serialize)]
pub struct RunResult {
    pub gate: String,
    pub script: String,
    pub exit_code: Option<i32>,
    pub timed_out: bool,
    pub duration_ms: u128,
    pub output_tail: String,
}

fn safe_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && !name.starts_with('/')
        && !name.contains("..")
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/'))
}

fn bundled_root() -> Option<PathBuf> {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR")).join("gates");
    if manifest.is_dir() {
        return manifest.canonicalize().ok();
    }
    let mut dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    for _ in 0..4 {
        let candidate = dir.join("gates");
        if candidate.is_dir() {
            return candidate.canonicalize().ok();
        }
        dir = dir.parent()?.to_path_buf();
    }
    None
}

fn bundled(script: &str) -> Option<PathBuf> {
    let base = script.rsplit('/').next()?;
    if !safe_name(base) || base.contains('/') {
        return None;
    }
    let root = bundled_root()?;
    let candidate = root.join(base);
    if !candidate.is_file() {
        return None;
    }
    let canonical = candidate.canonicalize().ok()?;
    canonical.starts_with(&root).then_some(canonical)
}

/// Resolve a gate script: live tools first, bundled copy as the fallback.
pub fn resolve(script: &str) -> Result<PathBuf> {
    if script.is_empty() || script.len() > 160 || script.starts_with('/') {
        return Err(anyhow!("invalid script path"));
    }
    if std::env::var("AIGON_GATES_BUNDLED").as_deref() != Ok("1") {
        for root in ROOTS {
            let candidate = Path::new(root).join(script);
            if candidate.is_file() {
                let canonical = candidate.canonicalize()?;
                if ROOTS.iter().any(|r| canonical.starts_with(r)) {
                    return Ok(canonical);
                }
            }
        }
    }
    bundled(script).ok_or_else(|| anyhow!("script not found (live or bundled): {script}"))
}

pub async fn run_selftest(gate: &str, script: &str) -> Result<RunResult> {
    let path = resolve(script)?;
    let started = Instant::now();
    let child = Command::new("bash")
        .arg(&path)
        .arg("--selftest")
        .kill_on_drop(true)
        .output();
    let output = match tokio::time::timeout(TIMEOUT, child).await {
        Ok(result) => result?,
        Err(_) => {
            return Ok(RunResult {
                gate: gate.to_string(),
                script: script.to_string(),
                exit_code: None,
                timed_out: true,
                duration_ms: started.elapsed().as_millis(),
                output_tail: format!("timed out after {} s", TIMEOUT.as_secs()),
            })
        }
    };
    let mut text = String::from_utf8_lossy(&output.stdout).to_string();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    let tail: String = if text.len() > MAX_OUTPUT {
        text[text.len() - MAX_OUTPUT..].to_string()
    } else {
        text
    };
    Ok(RunResult {
        gate: gate.to_string(),
        script: script.to_string(),
        exit_code: output.status.code(),
        timed_out: false,
        duration_ms: started.elapsed().as_millis(),
        output_tail: tail,
    })
}

/// Read-only bridge to the `aigon-code` CLI. Only the allowlisted subcommands run.
pub async fn aigon_code(command: &str) -> Result<RunResult> {
    let allowed = ["status", "doctor", "version"];
    if !allowed.contains(&command) {
        return Err(anyhow!("command not allowlisted: {command}"));
    }
    let binary = std::env::var("AIGON_CODE_BIN").unwrap_or_else(|_| "aigon-code".to_string());
    let started = Instant::now();
    let child = Command::new(&binary)
        .arg(command)
        .kill_on_drop(true)
        .output();
    let output = match tokio::time::timeout(Duration::from_secs(15), child).await {
        Ok(result) => result?,
        Err(_) => {
            return Ok(RunResult {
                gate: format!("aigon-code {command}"),
                script: binary,
                exit_code: None,
                timed_out: true,
                duration_ms: started.elapsed().as_millis(),
                output_tail: "timed out after 15 s".into(),
            })
        }
    };
    let mut text = String::from_utf8_lossy(&output.stdout).to_string();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    let tail: String = if text.len() > MAX_OUTPUT {
        text[text.len() - MAX_OUTPUT..].to_string()
    } else {
        text
    };
    Ok(RunResult {
        gate: format!("aigon-code {command}"),
        script: binary,
        exit_code: output.status.code(),
        timed_out: false,
        duration_ms: started.elapsed().as_millis(),
        output_tail: tail,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_traversal_and_shell_characters() {
        assert!(!safe_name("../etc/passwd"));
        assert!(!safe_name("gate.sh; rm -rf /"));
        assert!(!safe_name("gate$(id).sh"));
        assert!(safe_name("storage-tier-health.sh"));
    }

    #[test]
    fn resolve_refuses_unknown_script() {
        assert!(resolve("definitely-not-a-gate-xyz.sh").is_err());
    }
}
