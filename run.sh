#!/usr/bin/env bash
# run.sh — bootstrap + launch Otto.
# Idempotent: safe to run every time. Downloads everything needed on first run.
#
# Modes:
#   ./run.sh              push-to-talk: press ENTER to talk        ($0 idle)
#   ./run.sh --local      local on-device wake word (OpenWakeWord) ($0 idle)
#   ./run.sh --hotkey     hold a global hotkey to talk             ($0 idle)
#   ./run.sh --wake       cloud wake word "hey chat"   (streams continuously — NOT $0 idle)
#   ./run.sh --app        launch the SwiftUI palette app (auto-builds if needed; needs CLT)
set -euo pipefail
cd "$(dirname "$0")"

# ── colours ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BOLD="\033[1m"; RESET="\033[0m"
else
  GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
fi

ok()   { echo -e "${GREEN}✓${RESET}  $*"; }
step() { echo -e "${BOLD}→${RESET}  $*"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $*"; }
fail() { echo -e "${RED}✗${RESET}  $*" >&2; exit 1; }

# ── graceful Ctrl-C ─────────────────────────────────────────────────────────
APP_PID=""
trap '[ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; echo -e "\n${BOLD}bye.${RESET}"' INT TERM

# ── 1. Python venv ──────────────────────────────────────────────────────────
if [ ! -d .venv ]; then
  step "creating Python venv"
  python3 -m venv .venv || fail "python3 -m venv failed. Install Python 3.10+."
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q --upgrade pip >/dev/null

# ── 2. Python deps ──────────────────────────────────────────────────────────
step "checking Python dependencies"
pip install -q -r requirements.txt          # websockets, sounddevice
pip install -q -r requirements-local.txt    # sentence-transformers (always needed for retrieval)
ok "Python deps up to date"

# ── 3. agent-desktop ────────────────────────────────────────────────────────
if ! command -v agent-desktop >/dev/null 2>&1; then
  step "installing agent-desktop"
  if ! command -v npm >/dev/null 2>&1; then
    fail "npm not found. Install Node.js from https://nodejs.org then re-run."
  fi
  npm install -g agent-desktop || fail "npm install -g agent-desktop failed."
fi
ok "agent-desktop installed"

# Check accessibility permission (needed to control apps)
PERMS=$(agent-desktop permissions 2>/dev/null || echo '{}')
if echo "$PERMS" | python3 -c "import sys,json; p=json.load(sys.stdin); sys.exit(0 if p.get('data',{}).get('accessibility',{}).get('state')=='granted' else 1)" 2>/dev/null; then
  ok "accessibility permission granted"
else
  warn "accessibility permission not granted — app control will fail."
  warn "Fix: System Settings → Privacy & Security → Accessibility → add Terminal (or this app)"
fi

# ── 4. API key ───────────────────────────────────────────────────────────────
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
if [ -z "${OPENAI_API_KEY:-}" ]; then
  fail "OPENAI_API_KEY not set.\n   Fix: cp .env.example .env  then paste your key into .env"
fi
ok "API key loaded"

# ── 5. Pre-download models (one-time, then cached) ──────────────────────────
step "checking models (downloads once, then cached)"

# sentence-transformers embedding model for capability retrieval
python3 - <<'PYEOF'
import os, sys
model_name = os.environ.get("OTTO_EMBED_MODEL") or os.environ.get("VOICEOS_EMBED_MODEL") or "all-MiniLM-L6-v2"
try:
    from sentence_transformers import SentenceTransformer
    # will download if not cached (~22 MB), instant if already cached
    SentenceTransformer(model_name)
    print(f"  ✓  embedding model ready ({model_name})")
except Exception as e:
    print(f"  ⚠  could not load embedding model: {e}", file=sys.stderr)
    print(f"     Retrieval will be disabled this session.", file=sys.stderr)
PYEOF

# openWakeWord models (only needed for --local mode)
if [[ " $* " == *" --local "* ]]; then
  python3 - <<'PYEOF'
import sys
try:
    import openwakeword
    openwakeword.utils.download_models()
    print("  ✓  wake word models ready")
except Exception as e:
    print(f"  ⚠  could not download wake word models: {e}", file=sys.stderr)
PYEOF

  # also ensure faster-whisper + webrtcvad are present for --local mode
  pip install -q faster-whisper webrtcvad-wheels openwakeword >/dev/null
fi

ok "models ready"

# ── 6. Launch ────────────────────────────────────────────────────────────────
echo ""

# Strip launcher-only flags before handing the rest to Python.
FILTERED_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --local|--wake|--app) ;;                 # consumed here, not by the Python process
    *) FILTERED_ARGS+=("$arg") ;;
  esac
done

if [[ " $* " == *" --app "* ]]; then
  # Prefer a local make-built app; fall back to whatever Xcode left in DerivedData.
  APP=""
  if [ -d "$(pwd)/Otto/build/Otto.app" ]; then
    APP="$(pwd)/Otto/build/Otto.app"
  else
    for candidate in \
        "$(pwd)/Otto/build/Build/Products/Release/Otto.app" \
        "$(pwd)/Otto/build/Build/Products/Debug/Otto.app"; do
      [ -d "$candidate" ] && APP="$candidate" && break
    done
  fi
  if [ -z "$APP" ]; then
    APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Otto.app" \
          -path "*/Build/Products/*/Otto.app" \
          -not -path "*/Index.noindex/*" 2>/dev/null \
          | while IFS= read -r p; do printf "%s %s\n" "$(stat -f "%m" "$p")" "$p"; done \
          | sort -rn | head -1 | cut -d' ' -f2-)
  fi
  if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    step "Otto.app not found — building (requires Command Line Tools: xcode-select --install)"
    make app || fail "Build failed. Run 'xcode-select --install' if swiftc is missing."
    APP="$(pwd)/Otto/build/Otto.app"
  fi
  ok "found app: $APP"
  step "launching SwiftUI palette app"
  # Launch the binary directly (not open) so it inherits OPENAI_API_KEY and
  # OTTO_PROJECT_ROOT from this shell; stay in the process group so Ctrl-C
  # kills both the script and the UI together.
  OTTO_PROJECT_ROOT="$(pwd)" "$APP/Contents/MacOS/Otto" &
  APP_PID=$!
  echo -e "   ${BOLD}⌥Space${RESET} to summon the palette  ·  type or hold mic button to talk"
  wait "$APP_PID"
elif [[ " $* " == *" --local "* ]]; then
  OWW=${OTTO_OWW_MODEL:-${VOICEOS_OWW_MODEL:-hey_jarvis}}
  step "launching local wake-word engine (\$0 idle — nothing leaves your Mac until you speak the wake word)"
  echo -e "   Say ${BOLD}\"${OWW//_/ }, …\"${RESET} to trigger a command (set OTTO_OWW_MODEL to change)."
  echo ""
  python src/wake_listener.py "${FILTERED_ARGS[@]+${FILTERED_ARGS[@]}}"
elif [[ " $* " == *" --wake "* ]]; then
  step "launching cloud wake word — streams audio continuously (NOT \$0 idle)"
  echo -e "   Say ${BOLD}\"hey chat, …\"${RESET}. For \$0 idle use ${BOLD}--local${RESET} instead."
  echo ""
  python src/voice_agent.py "${FILTERED_ARGS[@]+${FILTERED_ARGS[@]}}"
elif [[ " $* " == *" --hotkey "* ]]; then
  step "launching hold-to-talk hotkey (\$0 idle)"
  echo ""
  python src/voice_agent.py "${FILTERED_ARGS[@]+${FILTERED_ARGS[@]}}"
else
  step "launching push-to-talk — press ENTER to talk (\$0 idle)"
  echo ""
  python src/voice_agent.py --push-to-talk "${FILTERED_ARGS[@]+${FILTERED_ARGS[@]}}"
fi
