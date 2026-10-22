# Threat model and test scope

AIGON PROOF is a single-host local-document executor with a read-only governance explorer and MCP interface. The default release uses a deterministic command/schema boundary and lexical retrieval; no generative model, training pipeline, external inbox, email integration or model-weight ingestion is present.

## Adversaries and trust boundaries

- Treat the MCP agent, command text, actor labels, JSON fields, HTTP headers, retrieved reference text and browser input as potentially hostile.
- The agent can propose typed actions but cannot authenticate as the human operator or provide authoritative document contents, classification, recipient scope or consent.
- Human approval binds exact actor, operation, server-owned document bytes and recipient. A passport grants one execution; verification itself never executes.
- Readable reference text is data, not an authorization policy or a replacement system prompt. The compiled executor enforces the boundary independently of a model following or ignoring retrieved instructions.
- The operator credential and signing key belong to the host's private state directory. Host administrators with read/write access to the process, binary or those secrets are outside this boundary.
- Default standalone mode reads the reviewed bundled corpus. Metadata indexes and corpus hashes are embedded in the binary. Mutated skill bodies, symlinks and changed bundled assets are rejected. Explicit live-canon path overrides are administrator capabilities, not network APIs.
- Host CLI and gate execution require explicit enablement and an API key of at least32 bytes. They run as the service user and are not an OS sandbox. Do not enable privileged adapters on an untrusted host.
- Browser responses restrict scripts by CSP hashes and disallow framing. Requests with a foreign/null Origin are rejected. Both regular JSON endpoints and nested MCP have a64KiB body limit. CLI requests without Origin remain supported.

## Authorized assessment

All active attack simulations target a disposable service bound to127.0.0.1 and disposable state. There is no scanning of Devpost, YouTube, AWS, customer accounts, other nodes or third-party networks. The fuzz campaign is bounded and deterministic. Positive execution controls use fictional/public bundled documents and real local filesystem writes.

The report distinguishes source review, automated SAST, dependency advisory checks, actual HTTP/MCP requests, browser tests and corpus tampering. It is a self-assessment with reproducible evidence, not an independent third-party penetration-test certificate.

## AI coverage and limits

Direct instruction overrides, Unicode/encoded command payloads, actor/metadata spoofing, fake approval, recipient swapping, altered signatures, replay and retrieval-file poisoning are tested at the actual enforcement boundary. An unsuccessful request means the engine did not authorize or execute it; it does not prove a downstream model resisted a jailbreak.

Training-data poisoning and generative-model jailbreak success rates are not applicable to the default model-free build. The optional `neural-embeddings` feature additionally requires `AIGON_EMBEDDINGS=1` and administrator-controlled model/cache provenance. Model-weight/backdoor robustness is NOT tested or certified. A source-tree hash detects changes against a trusted binary; it cannot defend against an administrator rebuilding both the executable and the manifest.

## Remaining product limits

Local bearer-style operator identity, no SSO/MFA, single-process local filesystem locking, synchronous durable state transactions and no distributed consensus. There is no production throughput SLO. API authorization is not an operating-system sandbox. Deployment needs HTTPS and private credentials. Unknown vulnerabilities and previously unseen attacks remain possible.

## Training and model-weight lifecycle

Current status: **no training/fine-tuning pipeline or training-data upload endpoint**. The default executable does not ingest model weights. Optional neural retrieval loads Multilingual E5 Small through fastembed/ONNX only when built with `--features neural-embeddings` and explicitly enabled with `AIGON_EMBEDDINGS=1`. This feature is an embedding loader, not a training system. Failed initialization reports lexical fallback.

Before any future training feature is released, require an approved dataset manifest with source, license, consent and SHA-256; separate untrusted examples from authorization policy; quarantine new data; test poisoned labels/instructions and compare clean versus poisoned held-out evaluations. Training approval must be separate from inference and execution approval. Record dataset/model versions, experiment configuration and rollback evidence.

Before enabling optional model loading in a security-sensitive deployment, verify the downloaded model and tokenizer against an independently approved digest and provenance manifest; use a private cache with no untrusted writers; test missing, truncated, altered and substituted weights; prohibit unsafe pickle-style deserialization and unintended network fallback. Loading occurs outside privileged execution authority. These model-provenance and training-poisoning checks are **release requirements for a future extension, NOT_RUN in this assessment**, not implemented protection claims. A trusted manifest must not be generated from an untrusted download and then treated as approval.

No model training, fine-tuning, external model download or GPU job is triggered by this assessment.
