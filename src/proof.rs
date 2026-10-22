//! Governed document workflow. Policy metadata is resolved on the server; approvals
//! are authenticated, action-bound and durable. Only execution consumes a passport.
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActionRequest {
    pub actor: String,
    pub operation: String,
    pub document_id: String,
    pub recipient_id: String,
    #[serde(default)]
    pub approval_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Document {
    pub id: &'static str,
    pub title: &'static str,
    pub classification: &'static str,
    pub content: &'static str,
}

pub fn documents() -> Vec<Document> {
    vec![
        Document { id: "client-contract", title: "Example client contract", classification: "personal",
            content: "FICTIONAL TEST DATA\nClient: Jane Example\nContract: C-2026-001\nService: document review\nFee: EUR 1200\n" },
        Document { id: "public-brief", title: "Public project brief", classification: "public",
            content: "AIGON PROOF\nAn inspectable authorization and execution workflow for agent actions.\nPublic information; no client data.\n" },
        Document { id: "redacted-summary", title: "Anonymised contract summary", classification: "public",
            content: "ANONYMISED SUMMARY\nOne service agreement for document review.\nNames, identifiers and fees have been removed.\n" },
    ]
}

#[derive(Debug, Clone, Serialize)]
pub struct Recipient {
    pub id: &'static str,
    pub label: &'static str,
    pub scope: &'static str,
}

pub fn recipients() -> Vec<Recipient> {
    vec![
        Recipient {
            id: "legal-team",
            label: "Legal team",
            scope: "internal",
        },
        Recipient {
            id: "external-partner",
            label: "External partner",
            scope: "external",
        },
        Recipient {
            id: "records",
            label: "Records archive",
            scope: "internal",
        },
    ]
}

/// Deliberate command language, not natural-language inference. Unknown words and
/// missing parameters are rejected; neither trust boundaries nor consent are guessed.
pub fn parse_command(command: &str) -> Result<ActionRequest> {
    let parts: Vec<_> = command.split_whitespace().collect();
    if parts.len() != 4 || parts[2] != "to" || !matches!(parts[0], "deliver" | "archive") {
        bail!("Use exactly: deliver <document-id> to <recipient-id>, or archive <document-id> to records");
    }
    let request = ActionRequest {
        actor: "mcp:assistant".into(),
        operation: parts[0].into(),
        document_id: parts[1].into(),
        recipient_id: parts[3].into(),
        approval_id: None,
    };
    resolve(&request)?;
    Ok(request)
}

fn resolve(request: &ActionRequest) -> Result<(Document, Recipient)> {
    if request.actor.trim().is_empty() || request.actor.len() > 120 {
        bail!("actor is required (maximum 120 characters)");
    }
    if !matches!(request.operation.as_str(), "deliver" | "archive") {
        bail!("unsupported operation");
    }
    let doc = documents()
        .into_iter()
        .find(|d| d.id == request.document_id)
        .context("unknown document; select a catalog document")?;
    let recipient = recipients()
        .into_iter()
        .find(|r| r.id == request.recipient_id)
        .context("unknown recipient; select a registered recipient")?;
    if request.operation == "archive" && recipient.id != "records" {
        bail!("archive requires the records recipient");
    }
    Ok((doc, recipient))
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn nonce() -> Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes).map_err(|e| anyhow!("entropy source unavailable: {e}"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |v, (a, b)| v | (a ^ b)) == 0
}
fn sign(key: &[u8], data: &[u8]) -> String {
    let mut block = [0u8; 64];
    if key.len() > 64 {
        block[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        block[..key.len()].copy_from_slice(key);
    }
    let mut inner = Sha256::new();
    inner.update(block.map(|b| b ^ 0x36));
    inner.update(data);
    let mut outer = Sha256::new();
    outer.update(block.map(|b| b ^ 0x5c));
    outer.update(inner.finalize());
    outer
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn action_hash(request: &ActionRequest) -> Result<String> {
    let (doc, recipient) = resolve(request)?;
    Ok(digest(&serde_json::to_vec(&serde_json::json!({
        "actor": request.actor, "operation": request.operation, "document_id": doc.id,
        "document_sha256": digest(doc.content.as_bytes()), "classification": doc.classification,
        "recipient_id": recipient.id, "scope": recipient.scope
    }))?))
}

#[derive(Debug, Clone, Serialize)]
pub struct Finding {
    pub rule: String,
    pub law: String,
    pub severity: String,
    pub reason: String,
}
#[derive(Debug, Clone, Serialize)]
pub struct Verdict {
    pub decision: String,
    pub findings: Vec<Finding>,
    pub action_hash: String,
    pub evaluated_at: u64,
    pub remediation: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Approval {
    pub id: String,
    pub action_hash: String,
    pub approver: String,
    pub approved: bool,
    pub created_at: u64,
    pub expires_at: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Passport {
    pub version: String,
    pub action_hash: String,
    pub approval_id: String,
    pub actor: String,
    pub recipient: String,
    pub issued_at: u64,
    pub expires_at: u64,
    pub nonce: String,
    pub signature: String,
}
fn passport_payload(p: &Passport) -> Vec<u8> {
    serde_json::to_vec(&(
        p.version.as_str(),
        p.action_hash.as_str(),
        p.approval_id.as_str(),
        p.actor.as_str(),
        p.recipient.as_str(),
        p.issued_at,
        p.expires_at,
        p.nonce.as_str(),
    ))
    .expect("serializable passport")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Receipt {
    pub id: String,
    pub action_hash: String,
    pub approval_id: String,
    pub approver: String,
    pub recipient_id: String,
    pub document_id: String,
    pub operation: String,
    pub document_sha256: String,
    pub path: String,
    pub bytes: usize,
    pub executed_at: u64,
    pub status: String,
}
#[derive(Default, Clone, Serialize, Deserialize)]
struct State {
    approvals: BTreeMap<String, Approval>,
    consumed: BTreeMap<String, String>,
    receipts: BTreeMap<String, Receipt>,
}
#[derive(Debug, Serialize)]
pub struct Verification {
    pub valid: bool,
    pub reason: String,
}

pub struct Engine {
    root: PathBuf,
    key: Vec<u8>,
    operator_hash: String,
    operator: String,
    state: Mutex<State>,
    _process_lock: File,
}

fn no_symlinks(path: &Path) -> Result<()> {
    for part in path.ancestors() {
        if part
            .symlink_metadata()
            .is_ok_and(|m| m.file_type().is_symlink())
        {
            bail!("symlink state path rejected");
        }
    }
    Ok(())
}

fn private_open(path: &Path) -> Result<File> {
    no_symlinks(path)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    Ok(options.open(path)?)
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    no_symlinks(path)?;
    let parent = path.parent().context("missing state parent")?;
    let temp = parent.join(format!(".write-{}", nonce()?));
    let result = (|| {
        let mut file = private_open(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if temp.exists() {
        let _ = fs::remove_file(temp);
    }
    result
}

impl Engine {
    pub fn open(
        root: &Path,
        key: Option<String>,
        operator_token: Option<String>,
        operator: &str,
    ) -> Result<Self> {
        no_symlinks(root)?;
        fs::create_dir_all(root)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(root, fs::Permissions::from_mode(0o700))?;
        }
        let root = root.canonicalize()?;
        let lock_path = root.join("process.lock");
        no_symlinks(&lock_path)?;
        let process_lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(lock_path)?;
        process_lock
            .try_lock()
            .context("another PROOF process owns this state directory")?;
        let secret = |filename: &str, supplied: Option<String>| -> Result<String> {
            if let Some(supplied) = supplied {
                if supplied.len() < 32 {
                    bail!("{filename} requires at least 32 characters");
                }
                return Ok(supplied);
            }
            let path = root.join(filename);
            no_symlinks(&path)?;
            if path.exists() {
                let value = fs::read_to_string(path)?;
                if value.len() < 32 {
                    bail!("invalid stored {filename}");
                }
                return Ok(value);
            }
            let value = nonce()?;
            let mut f = private_open(&path)?;
            f.write_all(value.as_bytes())?;
            f.sync_all()?;
            Ok(value)
        };
        let key = secret("signing.key", key)?.into_bytes();
        let token = secret("operator.token", operator_token)?;
        if operator.trim().is_empty() {
            bail!("operator identity is required");
        }
        let state_path = root.join("state.json");
        no_symlinks(&state_path)?;
        let state = if state_path.exists() {
            serde_json::from_slice(&fs::read(state_path)?)
                .context("state corruption; refusing to reset replay/approval history")?
        } else {
            State::default()
        };
        Ok(Self {
            root,
            key,
            operator_hash: digest(token.as_bytes()),
            operator: operator.into(),
            state: Mutex::new(state),
            _process_lock: process_lock,
        })
    }

    fn persist(&self, state: &State) -> Result<()> {
        atomic_write(&self.root.join("state.json"), &serde_json::to_vec(state)?)
    }
    pub fn authenticate(&self, token: &str) -> bool {
        ct_eq(
            self.operator_hash.as_bytes(),
            digest(token.as_bytes()).as_bytes(),
        )
    }

    fn verdict(&self, request: &ActionRequest, state: &State) -> Verdict {
        let mut verdict = Verdict {
            decision: "REVIEW".into(),
            findings: vec![],
            action_hash: String::new(),
            evaluated_at: now(),
            remediation: vec![],
        };
        let mut finding = |rule: &str, severity: &str, reason: &str| {
            verdict.findings.push(Finding {
                rule: rule.into(),
                law: if rule == "PROOF-1" {
                    "LAW-56"
                } else {
                    "LAW-78"
                }
                .into(),
                severity: severity.into(),
                reason: reason.into(),
            });
        };
        let (doc, recipient) = match resolve(request) {
            Ok(pair) => pair,
            Err(e) => {
                finding("PROOF-4", "BLOCK", &e.to_string());
                verdict.decision = "BLOCK".into();
                return verdict;
            }
        };
        verdict.action_hash = action_hash(request).unwrap_or_default();
        if doc.classification != "public" && recipient.scope == "external" {
            finding("PROOF-1", "BLOCK", "server catalog classifies this document as personal and this recipient as external");
            verdict.remediation.push("Select redacted-summary, or an internal recipient. Human approval cannot override this data policy.".into());
        }
        let approval = request
            .approval_id
            .as_ref()
            .and_then(|id| state.approvals.get(id));
        match approval {
            Some(a) if a.action_hash == verdict.action_hash && a.expires_at > now() && a.approved => {},
            Some(a) if a.action_hash == verdict.action_hash && !a.approved => finding("PROOF-2", "BLOCK", "operator explicitly denied this action"),
            _ => finding("PROOF-2", "REVIEW", "requires an authenticated human approval bound to this exact document, actor, operation and recipient"),
        }
        verdict.decision = if verdict.findings.iter().any(|f| f.severity == "BLOCK") {
            "BLOCK"
        } else if verdict.findings.is_empty() {
            "ALLOW"
        } else {
            "REVIEW"
        }
        .into();
        verdict
    }

    pub fn evaluate(&self, request: &ActionRequest) -> Verdict {
        self.verdict(
            request,
            &self.state.lock().unwrap_or_else(|e| e.into_inner()),
        )
    }

    pub fn approve(
        &self,
        request: &ActionRequest,
        reviewed_hash: &str,
        approved: bool,
        token: &str,
    ) -> Result<Approval> {
        if !self.authenticate(token) {
            bail!("operator authentication required");
        }
        let hash = action_hash(request)?;
        if !ct_eq(hash.as_bytes(), reviewed_hash.as_bytes()) {
            bail!("action changed since human review; review it again");
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow!("state lock poisoned"))?;
        if self
            .verdict(request, &state)
            .findings
            .iter()
            .any(|f| f.rule == "PROOF-1")
            && approved
        {
            bail!("blocked data policy cannot be approved");
        }
        let approval = Approval {
            id: nonce()?,
            action_hash: hash,
            approver: self.operator.clone(),
            approved,
            created_at: now(),
            expires_at: now() + 300,
        };
        // Supersede older decisions for the same action, so denial also revokes a
        // previously issued approval/passport for that exact action.
        let mut next = state.clone();
        next.approvals
            .retain(|_, a| a.action_hash != approval.action_hash || a.expires_at <= now());
        next.approvals.insert(approval.id.clone(), approval.clone());
        self.persist(&next)?;
        *state = next;
        Ok(approval)
    }

    pub fn issue(&self, request: &ActionRequest) -> Result<Passport> {
        let state = self
            .state
            .lock()
            .map_err(|_| anyhow!("state lock poisoned"))?;
        let verdict = self.verdict(request, &state);
        if verdict.decision != "ALLOW" {
            bail!("action requires {}", verdict.decision);
        }
        let approval = state
            .approvals
            .get(request.approval_id.as_ref().context("missing approval")?)
            .context("unknown approval")?;
        let mut passport = Passport {
            version: "aigon.proof/2".into(),
            action_hash: verdict.action_hash,
            approval_id: approval.id.clone(),
            actor: request.actor.clone(),
            recipient: request.recipient_id.clone(),
            issued_at: now(),
            expires_at: approval.expires_at,
            nonce: nonce()?,
            signature: String::new(),
        };
        passport.signature = sign(&self.key, &passport_payload(&passport));
        Ok(passport)
    }

    fn verify_inner(
        &self,
        passport: &Passport,
        request: Option<&ActionRequest>,
        state: &State,
    ) -> Result<()> {
        if passport.version != "aigon.proof/2"
            || !ct_eq(
                passport.signature.as_bytes(),
                sign(&self.key, &passport_payload(passport)).as_bytes(),
            )
        {
            bail!("signature mismatch");
        }
        if passport.expires_at <= now() || passport.issued_at > now() {
            bail!("passport expired or not yet valid");
        }
        let approval = state
            .approvals
            .get(&passport.approval_id)
            .context("approval revoked or unknown")?;
        if !approval.approved
            || approval.expires_at <= now()
            || approval.action_hash != passport.action_hash
        {
            bail!("approval denied, expired or changed");
        }
        if let Some(r) = request {
            if action_hash(r)? != passport.action_hash
                || r.approval_id.as_deref() != Some(&passport.approval_id)
            {
                bail!("action changed after authorisation");
            }
            if self.verdict(r, state).decision != "ALLOW" {
                bail!("current policy refuses execution");
            }
        }
        if state.consumed.contains_key(&passport.nonce)
            || state
                .consumed
                .contains_key(&format!("approval:{}", passport.approval_id))
        {
            bail!("passport replay detected; execution already reserved or completed");
        }
        Ok(())
    }

    pub fn verify(&self, passport: &Passport, request: Option<&ActionRequest>) -> Verification {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        match self.verify_inner(passport, request, &state) {
            Ok(()) => Verification { valid: true, reason: "signature, exact-action approval, freshness and durable replay checks passed; verification does not execute".into() },
            Err(e) => Verification { valid: false, reason: e.to_string() },
        }
    }

    pub fn execute(&self, passport: &Passport, request: &ActionRequest) -> Result<Receipt> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow!("state lock poisoned"))?;
        self.verify_inner(passport, Some(request), &state)?;
        let (doc, recipient) = resolve(request)?;
        let approval = state
            .approvals
            .get(&passport.approval_id)
            .context("approval absent")?
            .clone();
        // Reserve BOTH approval and nonce durably before I/O. Multiple passports
        // from the same consent still permit only a single execution.
        let approval_key = format!("approval:{}", approval.id);
        if state.consumed.contains_key(&approval_key) {
            bail!("approval already used; request a new human approval");
        }
        let mut reserved = state.clone();
        reserved
            .consumed
            .insert(passport.nonce.clone(), "reserved".into());
        reserved.consumed.insert(approval_key, "reserved".into());
        self.persist(&reserved)?;
        *state = reserved;
        let directory = self.root.join("inboxes").join(recipient.id);
        no_symlinks(&directory)?;
        fs::create_dir_all(&directory)?;
        let destination = directory.join(format!("{}.txt", passport.nonce));
        let mut file = private_open(&destination)?;
        file.write_all(doc.content.as_bytes())?;
        file.sync_all()?;
        File::open(&directory)?.sync_all()?;
        let delivered = fs::read(&destination)?;
        if digest(&delivered) != digest(doc.content.as_bytes()) {
            bail!("delivery read-back hash mismatch");
        }
        let receipt = Receipt {
            id: passport.nonce.clone(),
            action_hash: passport.action_hash.clone(),
            approval_id: approval.id,
            approver: approval.approver,
            recipient_id: recipient.id.into(),
            document_id: doc.id.into(),
            operation: request.operation.clone(),
            document_sha256: digest(&delivered),
            path: format!("inboxes/{}/{}.txt", recipient.id, passport.nonce),
            bytes: delivered.len(),
            executed_at: now(),
            status: "delivered_local".into(),
        };
        let mut complete = state.clone();
        complete
            .consumed
            .insert(passport.nonce.clone(), "completed".into());
        complete
            .receipts
            .insert(receipt.id.clone(), receipt.clone());
        self.persist(&complete)?;
        *state = complete;
        Ok(receipt)
    }

    pub fn receipts(&self) -> Result<Vec<Receipt>> {
        Ok(self
            .state
            .lock()
            .map_err(|_| anyhow!("state lock poisoned"))?
            .receipts
            .values()
            .cloned()
            .collect())
    }

    pub fn delivered(&self, id: &str) -> Result<(Receipt, String)> {
        let state = self
            .state
            .lock()
            .map_err(|_| anyhow!("state lock poisoned"))?;
        let receipt = state.receipts.get(id).context("receipt not found")?.clone();
        let path = self.root.join(&receipt.path);
        no_symlinks(&path)?;
        let bytes = fs::read(path)?;
        if digest(&bytes) != receipt.document_sha256 {
            bail!("delivered document integrity failure");
        }
        Ok((receipt, String::from_utf8(bytes)?))
    }
}

static ENGINE: OnceLock<std::result::Result<Engine, String>> = OnceLock::new();
pub fn engine() -> Result<&'static Engine> {
    ENGINE
        .get_or_init(|| {
            let root = std::env::var("AIGON_PROOF_STATE").unwrap_or_else(|_| ".aigon-proof".into());
            Engine::open(
                Path::new(&root),
                std::env::var("AIGON_PROOF_KEY").ok(),
                std::env::var("AIGON_OPERATOR_TOKEN").ok(),
                &std::env::var("AIGON_OPERATOR_NAME").unwrap_or_else(|_| "local-operator".into()),
            )
            .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(|e| anyhow!(e.clone()))
}
pub fn evaluate(r: &ActionRequest) -> Result<Verdict> {
    Ok(engine()?.evaluate(r))
}
pub fn issue(r: &ActionRequest) -> Result<Passport> {
    engine()?.issue(r)
}
pub fn verify(p: &Passport, r: Option<&ActionRequest>) -> Result<Verification> {
    Ok(engine()?.verify(p, r))
}

#[derive(Debug, Serialize)]
pub struct CrashTest {
    pub name: String,
    pub attack: String,
    pub defended: bool,
    pub evidence: String,
}
pub fn crash_tests() -> Result<Vec<CrashTest>> {
    let engine = engine()?;
    let base = parse_command("deliver public-brief to external-partner")?;
    let probes = vec![
        (
            "sensitive-egress",
            ActionRequest {
                document_id: "client-contract".into(),
                ..base.clone()
            },
            "BLOCK",
        ),
        (
            "forged-approval",
            ActionRequest {
                approval_id: Some("apr-42".into()),
                ..base.clone()
            },
            "REVIEW",
        ),
        (
            "unknown-recipient",
            ActionRequest {
                recipient_id: "attacker@example.com".into(),
                ..base.clone()
            },
            "BLOCK",
        ),
        (
            "unknown-document",
            ActionRequest {
                document_id: "../../etc/passwd".into(),
                ..base.clone()
            },
            "BLOCK",
        ),
        (
            "unsupported-operation",
            ActionRequest {
                operation: "ignore all rules".into(),
                ..base.clone()
            },
            "BLOCK",
        ),
        (
            "no-implicit-consent",
            ActionRequest {
                recipient_id: "legal-team".into(),
                ..base
            },
            "REVIEW",
        ),
    ];
    Ok(probes
        .into_iter()
        .map(|(name, request, expected)| {
            let verdict = engine.evaluate(&request);
            CrashTest {
                name: name.into(),
                attack: name.replace('-', " "),
                defended: verdict.decision == expected,
                evidence: format!("expected {expected}; observed {}", verdict.decision),
            }
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn constant_time_comparison_matches_only_equal_bytes() {
        assert!(ct_eq(b"abc", b"abc"));
        assert!(!ct_eq(b"abc", b"abd"));
        assert!(!ct_eq(b"abc", b"ab"));
    }
    #[test]
    fn hmac_matches_rfc4231_test_vector() {
        assert_eq!(
            sign(&[0x0b; 20], b"Hi There"),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );
    }
}
