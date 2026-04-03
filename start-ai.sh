#!/usr/bin/env bash
# start-ai.sh — Manage all AI backend services for Claude Code + Gemma
#               Gemma 4 (llama-server) + MCP web search + Anthropic→OpenAI proxy
#
# Usage:
#   ./start-ai.sh start   [MCP_PORT]   Start all services (default MCP port: 8090)
#   ./start-ai.sh stop                 Stop all services
#   ./start-ai.sh restart [MCP_PORT]   Restart all services
#   ./start-ai.sh status               Show status of all services
#   ./start-ai.sh logs                 Tail all logs live

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GEMMA="$SCRIPT_DIR/gemma.sh"
MCP="$SCRIPT_DIR/mcp_websearch.sh"
PROXY_SCRIPT="$SCRIPT_DIR/anthropic_proxy.py"
VENV="$SCRIPT_DIR/.mcp-venv"
PYTHON="$VENV/bin/python3"
MCP_PORT="${2:-8090}"
PROXY_PORT="${PROXY_PORT:-8081}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
PROXY_PID_FILE="$SCRIPT_DIR/.proxy.pid"
PROXY_LOG="$SCRIPT_DIR/.proxy.log"

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

for script in "$GEMMA" "$MCP"; do
    [ -x "$script" ] || chmod +x "$script"
done

# ── Proxy ─────────────────────────────────────────────────────────────────────

start_proxy() {
    [ -f "$PROXY_SCRIPT" ] || { err "anthropic_proxy.py not found at $PROXY_SCRIPT"; return 1; }
    [ -f "$PYTHON" ] || { err "Python venv not found. Run: ./mcp_websearch.sh start first"; return 1; }

    # Kill any existing proxy process
    if [ -f "$PROXY_PID_FILE" ] && kill -0 "$(cat "$PROXY_PID_FILE")" 2>/dev/null; then
        kill "$(cat "$PROXY_PID_FILE")" 2>/dev/null; sleep 1
    fi
    lsof -ti tcp:"$PROXY_PORT" | xargs kill -9 2>/dev/null || true

    info "Starting Anthropic→OpenAI proxy on port $PROXY_PORT..."
    LLAMA_BASE="http://localhost:$LLAMA_PORT/v1" PROXY_PORT="$PROXY_PORT" \
    nohup "$PYTHON" "$PROXY_SCRIPT" >> "$PROXY_LOG" 2>&1 &
    echo $! > "$PROXY_PID_FILE"

    for i in $(seq 1 20); do
        curl -sf "http://localhost:$PROXY_PORT/health" &>/dev/null && ok "Proxy ready (port $PROXY_PORT)" && return 0
        sleep 1; printf "."
    done
    echo ""
    err "Proxy failed to start. Check: tail -20 $PROXY_LOG"
    return 1
}

stop_proxy() {
    if [ -f "$PROXY_PID_FILE" ]; then
        local pid
        pid=$(cat "$PROXY_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            ok "Proxy stopped (PID $pid)"
        fi
        rm -f "$PROXY_PID_FILE"
    fi
    lsof -ti tcp:"$PROXY_PORT" | xargs kill -9 2>/dev/null || true
}

proxy_status() {
    if [ -f "$PROXY_PID_FILE" ] && kill -0 "$(cat "$PROXY_PID_FILE")" 2>/dev/null; then
        if curl -sf "http://localhost:$PROXY_PORT/health" &>/dev/null; then
            ok "Proxy running (PID $(cat "$PROXY_PID_FILE"), port $PROXY_PORT)"
        else
            warn "Proxy process alive but not responding on port $PROXY_PORT"
        fi
    else
        err "Proxy not running"
    fi
}

# ── Combined ──────────────────────────────────────────────────────────────────

start_all() {
    echo ""
    echo -e "${BOLD}========================================"
    echo -e "  AI Stack — Starting"
    echo -e "========================================${NC}"
    echo ""

    echo -e "${BOLD}[1/3] Starting MCP web search (port $MCP_PORT)...${NC}"
    "$MCP" start "$MCP_PORT"

    echo ""
    echo -e "${BOLD}[2/3] Starting Gemma 4 (port $LLAMA_PORT)...${NC}"
    "$GEMMA" start

    echo ""
    echo -e "${BOLD}[3/3] Starting Anthropic→OpenAI proxy (port $PROXY_PORT)...${NC}"
    start_proxy

    echo ""
    echo -e "${BOLD}========================================"
    echo -e "  AI Stack — Running"
    echo -e "========================================${NC}"
    echo ""
    echo -e "  Gemma 4 API     : ${CYAN}http://localhost:$LLAMA_PORT/v1${NC}"
    echo -e "  Gemma 4 Web UI  : ${CYAN}http://localhost:$LLAMA_PORT${NC}"
    echo -e "  Anthropic Proxy : ${CYAN}http://localhost:$PROXY_PORT${NC}"
    echo -e "  MCP Web Search  : ${CYAN}http://localhost:$MCP_PORT/mcp${NC}"
    echo ""
    echo -e "  Stop    : $0 stop"
    echo -e "  Status  : $0 status"
    echo -e "  Logs    : $0 logs"
    echo ""
}

stop_all() {
    echo ""
    echo -e "${BOLD}========================================"
    echo -e "  AI Stack — Stopping"
    echo -e "========================================${NC}"
    echo ""

    echo -e "${BOLD}[1/3] Stopping proxy...${NC}"
    stop_proxy

    echo ""
    echo -e "${BOLD}[2/3] Stopping Gemma 4...${NC}"
    "$GEMMA" stop

    echo ""
    echo -e "${BOLD}[3/3] Stopping MCP web search...${NC}"
    "$MCP" stop

    echo ""
    ok "All services stopped."
    echo ""
}

# ── CLI ────────────────────────────────────────────────────────────────────────

case "${1:-start}" in
    start)
        start_all
        ;;
    stop)
        stop_all
        ;;
    restart)
        stop_all
        sleep 1
        start_all
        ;;
    status)
        echo ""
        echo -e "${BOLD}=== Gemma 4 ===${NC}"
        "$GEMMA" status
        echo ""
        echo -e "${BOLD}=== MCP Web Search ===${NC}"
        "$MCP" status
        echo ""
        echo -e "${BOLD}=== Anthropic→OpenAI Proxy ===${NC}"
        proxy_status
        echo ""
        ;;
    logs)
        echo "Tailing all logs (Ctrl+C to exit)..."
        tail -f "$SCRIPT_DIR/.llama-server.log" \
                "$SCRIPT_DIR/.mcp-websearch.log" \
                "$PROXY_LOG" 2>/dev/null
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs} [MCP_PORT]"
        echo ""
        echo "  start   [port]   Start Gemma 4 + MCP + Proxy (default MCP port: 8090)"
        echo "  stop             Stop all services"
        echo "  restart [port]   Restart all services"
        echo "  status           Show status of all services"
        echo "  logs             Tail all logs live"
        echo ""
        echo "Environment variables:"
        echo "  PROXY_PORT=8081  Anthropic→OpenAI proxy port"
        echo "  LLAMA_PORT=8080  Gemma/llama-server port"
        echo ""
        echo "Examples:"
        echo "  $0 start"
        echo "  $0 start 9000    # custom MCP port"
        echo "  $0 stop"
        exit 1
        ;;
esac
