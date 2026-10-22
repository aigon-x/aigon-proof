# Bundled gate scripts

These are the 154 scripts referenced by the gate catalogue, copied verbatim so the MCP server can
run `--selftest` on a machine that does not have the AIGON tree.

They are **host checks**: most inspect docker, systemd, files or the runtime, and will fail loudly
when those services are absent. A failure is a measurement of the host, not of this repository.
The server prefers live scripts under `/srv/aigon/tools/**`; the bundle is the fallback.
