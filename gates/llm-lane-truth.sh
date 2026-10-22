#!/usr/bin/env bash
# GATE-257 (moduł runnera) — deleguje do kanonicznej bramy LAW-LLM-LANE-1.
# Treść bramki: /srv/aigon/tools/gates/llm-lane-truth.sh (--selftest = dowód negatywny).
exec /srv/aigon/tools/gates/llm-lane-truth.sh "${@:---quiet}"
