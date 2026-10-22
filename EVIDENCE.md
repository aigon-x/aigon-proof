# AIGON PROOF v2 — executed release checks, 2026-10-22

- Rust: 12 unit + 23 workflow regressions + 1 standalone = 36 passed, 0 failed.
- cargo fmt --check: PASS. Clippy release all-targets with -D warnings: PASS.
- Chromium against the actual current Rust binary: real file delivery and SHA-256 read-back, restart history, denial, revocation after signing, archive, six policy probes, ambiguous-command rejection, unauthorized-operator rejection, MCP initialization and actual MCP tool execution: PASS.
- Desktop/tablet/mobile widths 1920/768/390: no horizontal overflow. Keyboard focus and reduced-motion checks: PASS. Zero JavaScript exceptions; expected HTTP403 responses occur during negative tests.
- Media: actual live browser recording, 155.76s, H.264 1920x1080, AAC, English narration/subtitles. No playback acceleration.
- Secret scan: current curated release passes built-in gitleaks rules with only the precise deliberate OBS-02 fake canary allowlisted.

These are observed feature checks, not proof of universal production security or user satisfaction. WOW reaction remains a user judgement. The service is a single-host local document executor; see SECURITY.md.

Public demonstration (ElevenLabs Cornelius — English and Polish audio tracks, PL/EN subtitles): https://www.youtube.com/watch?v=JkrFSnDyBrM
Polish-narrated version: https://www.youtube.com/watch?v=mihcNVdBAbU

## Readability correction after user review

The original film was rejected by the user for small/blurred text, framing and a white field. The corrected film is native3840×2160,142.3s, with150% framing, a single-column presentation view and dark native controls. Source frames are lossless PNG. Reviewed encoded review/receipt frames; actual current binary includes the exact HTML and passes all11 browser checks. Zero JavaScript exceptions. Scene cuts remove idle waiting; no playback acceleration. Narration remains ElevenLabs Cornelius — Wise Sage.

SZAMANI AI: https://szamani.ai/ · kontakt@szamani.ai
