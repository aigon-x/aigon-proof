# Licensing and provenance of bundled content

The **code** in this repository is MIT (see `LICENSE`).

## Bundled canon (`fixtures/canon/`, `gates/`)

These files are snapshots of the AIGON constitution, gate catalogue, capability manifest, gate
scripts and measured scores. They were written and are owned by SZAMANI AI and are published here
under the same MIT licence. The snapshot is read-only: the server never edits canonical files.

## Bundled skills (`skills/`)

The 53 curated `SKILL.md` files come from SZAMANI AI's internal skill library (`/opt/PROD/skills`). They
are internal operating documents, published under MIT with the following caveats:

1. **Third-party names and API samples** inside the prompts (for example Google, AWS, GitLab,
   Cloudflare, PayPal, Roblox) remain the property of their owners. They appear as technical
   references, not as redistributed vendor assets.
2. **Credentials were removed.** Every bundled prompt was scanned with gitleaks; provider tokens,
   private keys and default device passwords were replaced with `[REDACTED_*]` / `admin:<PASSWORD>`,
   and the index was rehashed. This public release is a clean source snapshot; it does not include the private development repository history.
3. **Single-author provenance.** All files were produced by SZAMANI AI operators or its agents; no
   third-party skill library was copied wholesale. If a future contribution contradicts this, the
   file must be removed or relicensed before publication.

## Exception: `skills/mcp/mcp-builder`

This one skill is Apache-2.0 (see `skills/mcp/mcp-builder/LICENSE.txt`); its licence and notices
are retained. The MIT statement above covers the other 52 skills and the code.

## What is *not* covered

Nothing in this repository grants rights to the AIGON runtime, the internal mesh, client data, or
any vendor SDK. The server is a read-only viewer over a published snapshot.
