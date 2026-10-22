# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-10-22

First public release, prepared for the Build, Ship, Shape: Amazon Developer Hackathon
(Alexa+ track).

### Added

- Self-hosted MCP server over Streamable HTTP, protocol `2025-11-25` (`rmcp` 3.6),
  alongside stdio.
- Typed action contract: `deliver <document-id> to <recipient-id>`,
  `archive <document-id> to records`. Ambiguous commands fail instead of being guessed.
- Server-owned classification and trust boundary; external delivery of personal data is
  blocked and cannot be approved.
- Operator-authenticated human approval bound to actor, operation, exact document bytes,
  recipient and trust boundary; approvals expire after five minutes.
- Signed action passports with one-approval-one-execution semantics.
- Durable replay rejection that survives a restart.
- Execution that writes real bytes to a registered local inbox and returns a receipt
  after `fsync` and SHA-256 read-back.
- Governance explorer with a standalone bundle of laws, gates and curated skills.
- Six read-only negative policy probes (`/api/proof/crash-tests`).
- Reproducible security assessment and threat model in `docs/security/`.

### Security

- Signing and operator keys are generated on first boot and stored privately outside Git.
- Verification never consumes a passport; execution consumes approval and nonce.
- State updates use private files, `fsync` and atomic rename, with a single-server lock.

[Unreleased]: https://github.com/aigon-x/aigon-proof/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aigon-x/aigon-proof/releases/tag/v0.1.0
