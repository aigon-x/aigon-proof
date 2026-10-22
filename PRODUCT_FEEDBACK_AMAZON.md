# Amazon Developer Hackathon — Product Feedback

## Which tools, APIs and SDKs did you use?
AIGON PROOF implements the Alexa+ track's self-hosted Model Context Protocol route: official Rust rmcp SDK 3.6, Streamable HTTP transport and protocol 2025-11-25. Tokio and Axum supply the HTTP server; serde represents typed requests. The browser demo is an Alexa+-style simulation, not a native preview integration. SHA-256/HMAC signs demonstration action passports and OpenTelemetry captures instrumented operations.

## What worked well?
MCP tools provide a consistent contract for a policy service, and the Rust SDK makes it possible to expose the same engine through standard MCP and a web explorer. The standalone fixture bundle makes external evaluation realistic without internal AIGON files.

## What needs work?
SDK versions and protocol revisions require careful migration. A simple official end-to-end example of Streamable HTTP with authentication, user approval, tool permissions and safe negative tests would greatly reduce developer uncertainty. Teams without Alexa+ Preview access would benefit from an official local MCP simulator.

## How was onboarding?
The original server used an older protocol and transport, so we migrated to current Streamable HTTP and tested initialization. Making an internal canonical ruleset runnable from a public clone required independent fixture packaging. Please see FRICTION-LOG.md for observed problems rather than treating speculation as measured friction.

## Would you build again with these tools?
Yes. Open MCP is a useful integration boundary for governed agent actions. For production we would add identity-bound human authorization, an audited cryptographic implementation, and persistent distributed replay handling.

## Mini challenges
No AWS production service usage or second qualifying open-source contribution is verified here. Do not submit into those mini challenges unless the relevant evidence and contribution URLs are available.

