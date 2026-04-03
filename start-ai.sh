#!/usr/bin/env bash
# start-ai.sh — Start / stop / restart Gemma 4 + MCP web search together

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GEMMA="$SCRIPT_DIR/gemma.sh"
MCP="$SCRIPT_DIR/mcp_websearch.sh"
MCP_PORT="${2:-8090}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

for script in "$GEMMA" "$MCP"; do
    [ -x "$script" ] || chmod +x "$script"
done

start_all() {
    echo ""
    echo -e "${BOLD}========================================"
    echo -e "  AI Stack — Starting"
    echo -e "========================================${NC}"
    echo ""

    echo -e "${BOLD}[1/2] Starting MCP web search (port $MCP_PORT)...${NC}"
    "$MCP" start "$MCP_PORT"

    echo ""
    echo -e "${BOLD}[2/2] Starting Gemma 4 (port 8080)...${NC}"
    "$GEMMA" start

    echo ""
    echo -e "${BOLD}========================================"
    echo -e "  AI Stack — Running"
    echo -e "========================================${NC}"
    echo ""
    echo -e "  Gemma 4 Web UI  : http://localhost:8080"
    echo -e "  Gemma 4 API     : http://localhost:8080/v1"
    echo -e "  MCP Web Search  : http://localhost:$MCP_PORT/mcp"
    echo ""
    echo -e "  Stop  : $0 stop"
    echo -e "  Logs  : $0 logs"
    echo ""
}

stop_all() {
    echo ""
    echo -e "${BOLD}========================================"
    echo -e "  AI Stack — Stopping"
    echo -e "========================================${NC}"
    echo ""
    echo -e "${BOLD}[1/2] Stopping Gemma 4...${NC}"
    "$GEMMA" stop
    echo ""
    echo -e "${BOLD}[2/2] Stopping MCP web search...${NC}"
    "$MCP" stop
    echo ""
    ok "All services stopped."
    echo ""
}

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
        ;;
    logs)
        echo "Tailing both logs (Ctrl+C to exit)..."
        tail -f "$SCRIPT_DIR/.llama-server.log" "$SCRIPT_DIR/.mcp-websearch.log"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs} [MCP_PORT]"
        echo ""
        echo "  start   [port]   Start Gemma 4 + MCP (default MCP port: 8090)"
        echo "  stop             Stop both"
        echo "  restart [port]   Restart both"
        echo "  status           Show status of both"
        echo "  logs             Tail both logs live"
        echo ""
        echo "Examples:"
        echo "  $0 start"
        echo "  $0 start 9000"
        echo "  $0 stop"
        exit 1
        ;;
esac
