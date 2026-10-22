# Reproduce the scoped security assessment

Use a fresh checkout and disposable state. Install Rust, Python 3, Chromium and Playwright. The active adversarial script accepts no remote target and starts its own loopback process. It creates real local deliveries, never simulated consent or external email.

```sh
cargo fmt --check
cargo clippy --release --all-targets --locked -- -D warnings
cargo test --release --locked
cargo build --release --locked
python3 scripts/check_security.py --source . --binary target/release/aigon-governance-mcp --output .agent-artifacts/security-review
python3 scripts/check_browser.py
cargo install cargo-audit --version 0.22.2 --locked
RUST_LOG=off cargo audit --json > dependency-audit.json
python3 scripts/extract_browser_scripts.py --output .agent-artifacts/security-js
semgrep scan --config p/rust --config p/javascript --metrics off --no-git-ignore --json src .agent-artifacts/security-js > sast.json
python3 scripts/check_sast_report.py sast.json
gitleaks git . --redact --report-format json --report-path secret-scan.json --config .gitleaks.toml
python3 scripts/benchmark_local.py --binary target/release/aigon-governance-mcp --output benchmark.json
```

Run Rust tests with deployment variables unset: `AIGON_API_KEY`, `AIGON_ALLOWED_HOSTS`, `AIGON_ALLOW_ANY_HOST`, `AIGON_ALLOW_RUN`, `AIGON_ALLOW_CODE_BRIDGE`. The HTTP assessment itself sanitizes AIGON/OTEL environment variables. Scanners require access to their official public advisory/rule databases; no active third-party attack is performed. Preserve scanner errors and nonzero exits. Missing/empty reports are not a pass. Gitleaks findings must stay redacted.

The public CI repeats default-feature Rust, adversarial and Chromium checks, full-history secret scanning, current RustSec and Rust/JavaScript SAST. A workflow definition is not evidence of a completed run; consult the actual Actions run for its commit.

`--features neural-embeddings` is an optional model-loading extension, disabled by default. The current assessment does not download weights or train models. Follow the threat model before enabling it. No third-party pentest certificate or universal AI-security claim is implied.
