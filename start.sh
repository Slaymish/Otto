#!/usr/bin/env bash
# Launch the whole of Otto. Run this IN YOUR OWN TERMINAL (so the clean
# ⚙ tool-call output is visible for screen recording, and so the accessibility
# keeper is "trusted").
#
#   cd .../otto && ./start.sh
#
# Hold LEFT OPTION + Z (⌥Z) anywhere to talk. Ctrl-C to quit.
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate
set -a; [ -f .env ] && source .env; set +a

# 1. keep Claude Desktop's accessibility tree forced on (for the ask_claude beat)
pkill -f ax_keeper.py 2>/dev/null || true
python src/ax_keeper.py >/dev/null 2>&1 &

# 2. black-and-white waveform overlay (top of screen while you talk)
pkill -f overlay.py 2>/dev/null || true
python src/overlay.py >/dev/null 2>&1 &

# 3. Otto, in the foreground so you SEE every ⚙ tool call / ✓ result.
#    (set OTTO_MIC to target a specific mic, e.g. OTTO_MIC=Scarlett ./start.sh)
pkill -f voice_app.py 2>/dev/null || true
MIC="${OTTO_MIC:-${VOICEOS_MIC:-}}"
exec python src/voice_app.py --combo opt+z ${MIC:+--mic "$MIC"}
