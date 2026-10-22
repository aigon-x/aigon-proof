# Current live demonstration narration

The film records the actual Rust server, UI approval, signed action, real local delivery,
read-back verification, refusal of tampering/replay and persisted history after a restart.
It does not claim native Alexa+ Preview integration or external email delivery.

0. An assistant saying done is not proof. AIGON PROOF gives each action an exact review, an authenticated approval, and a receipt for the work actually performed.
1. First, a client contract is addressed to an external partner. The server knows the document contains personal data. It blocks the action. Even an operator cannot approve this policy violation.
2. We explicitly choose the anonymised summary instead. The document and recipient are shown before approval. Nothing in this command invents consent or silently changes the trust boundary.
3. The operator unlocks approval with a private credential. That credential is never part of the agent's command or passport.
4. Approve once records who approved the exact action fingerprint. The server now signs a short-lived passport. This is permission, not a delivery claim.
5. Changing the recipient invalidates the authorization. The original approved action remains available to execute.
6. Execute performs the work. The server writes actual document bytes into the recipient's local inbox, reads them back, verifies their SHA-256 hash, and persists this receipt.
7. A second execution is rejected. One human approval cannot be reused through another passport either.
8. After restarting the server, the receipt history is still here. Approval and replay records are durable, not just browser state.
9. The operator can also deny or revoke an action. A denial does not produce a usable passport.
10. Six negative policy probes check forged approval, sensitive egress and unknown parameters. The demonstration also exercises real recipient tampering and replay.
11. The same Rust service exposes the governance explorer and MCP protocol 2025-11-25. AIGON PROOF: approve the action, verify the outcome.
