#!/usr/bin/env bash
# claude-code-gemma.sh — Launch Claude Code backed by a local Gemma 4 model
#
# Prerequisites (handled by start-ai.sh):
#   - Gemma 4 running via llama-server (port 8080)
#   - Anthropic→OpenAI proxy running (port 8081)
#
# Usage:
#   ./claude-code-gemma.sh           Launch Claude Code (starts services if needed)
#   ./claude-code-gemma.sh --help    Pass any Claude Code flags through
#
# Environment:
#   CLAUDE_CODE_DIR   Path to the claude-code source build
#                     (default: ~/projects/claude-code-source-build)
#   PROXY_PORT        Anthropic proxy port (default: 8081)
#   LLAMA_PORT        Gemma/llama-server port (default: 8080)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_BUILD="${CLAUDE_CODE_DIR:-$HOME/projects/claude-code-source-build}"
PROXY_PORT="${PROXY_PORT:-8081}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
MODEL_NAME="gemma-4-e4b"
CLAUDE_CONFIG="$HOME/.claude-gemma"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${CYAN}[--]${NC} $*"; }
die()  { err "$*"; exit 1; }

# ── Validate ──────────────────────────────────────────────────────────────────

[ -f "$CLAUDE_BUILD/dist/cli.js" ] || die "Claude Code not built at $CLAUDE_BUILD
  → Clone and build: https://github.com/anthropics/claude-code
  → Or set: CLAUDE_CODE_DIR=/path/to/claude-code ./claude-code-gemma.sh"

command -v node &>/dev/null || die "node not found — install Node.js >= 20"

# ── Auto-create ~/.claude-gemma/settings.json ─────────────────────────────────

setup_claude_config() {
    mkdir -p "$CLAUDE_CONFIG"
    local settings="$CLAUDE_CONFIG/settings.json"
    if [ ! -f "$settings" ]; then
        info "Creating $settings with default permissions..."
        cat > "$settings" << 'EOF'
{
  "permissions": {
    "allow": [
      "Read(/home/**)",
      "Read(/tmp/**)",
      "Read(/usr/**)",
      "Read(/opt/**)",
      "Bash(ls:*)",
      "Bash(find:*)",
      "Bash(cat:*)",
      "Bash(echo:*)",
      "Bash(grep:*)",
      "Bash(sed:*)",
      "Bash(awk:*)",
      "Bash(wc:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(sort:*)",
      "Bash(git:*)",
      "Bash(npm:*)",
      "Bash(node:*)",
      "Bash(python3:*)",
      "Bash(pip:*)",
      "Bash(pip3:*)",
      "Bash(curl:*)",
      "Bash(wget:*)",
      "Bash(chmod:*)",
      "Bash(mkdir:*)",
      "Bash(cp:*)",
      "Bash(mv:*)",
      "Bash(rm:*)",
      "Bash(touch:*)",
      "Bash(docker:*)",
      "Bash(sudo:*)",
      "Bash(apt:*)",
      "Bash(apt-get:*)",
      "Bash(make:*)",
      "Bash(go:*)",
      "Bash(cargo:*)",
      "WebSearch"
    ]
  }
}
EOF
        ok "Config created at $settings"
    else
        ok "Using existing config at $settings"
    fi
}

setup_claude_config

# ── Ensure backend services are running ───────────────────────────────────────

if ! curl -sf "http://localhost:$PROXY_PORT/health" &>/dev/null; then
    warn "Backend not running — starting all services..."
    echo ""
    "$SCRIPT_DIR/start-ai.sh" start
    echo ""
    curl -sf "http://localhost:$PROXY_PORT/health" &>/dev/null \
        || die "Services failed to start. Run: $SCRIPT_DIR/start-ai.sh start"
else
    ok "Backend running (proxy :$PROXY_PORT)"
fi

# ── Launch Claude Code ────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}=================================================${NC}"
echo -e "${BOLD}  Claude Code × Gemma 4 (Local)${NC}"
echo -e "${BOLD}=================================================${NC}"
echo ""
info "Config  : $CLAUDE_CONFIG"
info "Proxy   : http://localhost:$PROXY_PORT"
info "Gemma   : http://localhost:$LLAMA_PORT/v1"
info "Model   : $MODEL_NAME"
echo ""
echo -e "  Stop backend anytime: ${CYAN}$SCRIPT_DIR/start-ai.sh stop${NC}"
echo ""

exec env \
    ANTHROPIC_BASE_URL="http://localhost:$PROXY_PORT" \
    ANTHROPIC_MODEL="$MODEL_NAME" \
    ANTHROPIC_API_KEY="local-gemma" \
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG" \
    node "$CLAUDE_BUILD/dist/cli.js" "$@"
