#!/usr/bin/env bash
# GATE-257 (moduł runnera) — deleguje do kanonicznej bramy LAW-LLM-LANE-1.
# Treść bramki: /opt/PROD/tools/gates/llm-lane-truth.sh (--selftest = dowód negatywny).
exec /opt/PROD/tools/gates/llm-lane-truth.sh "${@:---quiet}"
