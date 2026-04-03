#!/usr/bin/env bash
# mcp_websearch.sh — Install and manage a free web search MCP server (SearXNG + MCP bridge)
# Usage: ./mcp_websearch.sh start [PORT]
#        ./mcp_websearch.sh stop
#        ./mcp_websearch.sh restart [PORT]
#        ./mcp_websearch.sh status
#        ./mcp_websearch.sh logs

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$PROJECT_DIR/.mcp-websearch.pid"
LOG_FILE="$PROJECT_DIR/.mcp-websearch.log"

# ── Args ──────────────────────────────────────────────────────────────────────
COMMAND="${1:-start}"
MCP_PORT="${2:-8090}"
SEARXNG_PORT="8888"
SEARXNG_URL="http://localhost:$SEARXNG_PORT"
VENV_DIR="$PROJECT_DIR/.mcp-venv"
PYTHON="$VENV_DIR/bin/python3"
# ─────────────────────────────────────────────────────────────────────────────

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
step() { echo -e "\n${BOLD}>>> $*${NC}"; }
die()  { err "$*"; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

searxng_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^searxng$" || \
    curl -sf "http://localhost:$SEARXNG_PORT" &>/dev/null
}

install_deps() {
    step "Checking dependencies"

    # Python
    if ! command -v python3 &>/dev/null; then
        die "python3 not found. Run: sudo apt-get install -y python3-full"
    fi
    ok "python3 $(python3 --version)"

    # Create venv if not exists (avoids Ubuntu 24.04 externally-managed-environment error)
    if [ ! -d "$VENV_DIR" ]; then
        info "Creating Python venv at $VENV_DIR..."
        python3 -m venv "$VENV_DIR"
        ok "venv created"
    else
        ok "venv exists"
    fi

    # Docker (for SearXNG)
    if ! command -v docker &>/dev/null; then
        info "Docker not found — installing..."
        sudo apt-get install -y docker.io -qq
        sudo systemctl start docker
    fi

    # Fix permissions if needed — add user to docker group and use sudo for now
    if ! docker info &>/dev/null 2>&1; then
        warn "Docker permission denied — fixing (you won't need sudo after next login)..."
        sudo usermod -aG docker "$USER"
        sudo chmod 666 /var/run/docker.sock
        # Verify fix worked
        if ! docker info &>/dev/null 2>&1; then
            die "Still can't reach Docker. Try: sudo systemctl start docker"
        fi
    fi
    ok "docker OK"

    # Install mcp + uvicorn + starlette into venv
    if ! "$PYTHON" -c "import mcp" &>/dev/null 2>&1; then
        info "Installing mcp[cli] + uvicorn + starlette into venv..."
        "$VENV_DIR/bin/pip" install -q "mcp[cli]" uvicorn starlette
    fi
    ok "mcp + uvicorn + starlette installed"
}

start_searxng() {
    if searxng_running; then
        ok "SearXNG already running on port $SEARXNG_PORT"
        return
    fi

    # Remove stopped container if it exists
    docker rm searxng 2>/dev/null || true

    # Write SearXNG settings that enable JSON API format
    SEARXNG_CFG_DIR="$PROJECT_DIR/.searxng"
    mkdir -p "$SEARXNG_CFG_DIR"
    cat > "$SEARXNG_CFG_DIR/settings.yml" << 'EOF'
use_default_settings: true
server:
  secret_key: "mcp-searxng-local-key-change-me"
  limiter: false
  public_instance: false
search:
  safe_search: 0
  formats:
    - html
    - json
EOF
    ok "SearXNG settings written (JSON API enabled)"

    info "Starting SearXNG on port $SEARXNG_PORT..."
    docker run -d \
        --name searxng \
        --restart unless-stopped \
        -p "$SEARXNG_PORT:8080" \
        -v "$SEARXNG_CFG_DIR:/etc/searxng" \
        searxng/searxng >> "$LOG_FILE" 2>&1

    # Wait for SearXNG to be ready
    for i in $(seq 1 30); do
        if curl -sf "$SEARXNG_URL" &>/dev/null; then
            ok "SearXNG is up at $SEARXNG_URL"
            return
        fi
        sleep 1
        printf "."
    done
    echo ""
    warn "SearXNG started but took longer than expected — check: docker logs searxng"
}

write_mcp_server() {
    # Write a minimal MCP HTTP server that uses SearXNG only
    cat > "$PROJECT_DIR/.mcp_websearch_server.py" << 'PYEOF'
#!/usr/bin/env python3
"""
MCP web search server using FastMCP — SearXNG only.
Uses streamable-http with CORS middleware for llama.cpp WebUI compatibility.
"""
import os, json, urllib.parse, urllib.request
import uvicorn
from mcp.server.fastmcp import FastMCP
from starlette.middleware.cors import CORSMiddleware

SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://localhost:8888")
PORT = int(os.environ.get("MCP_PORT", "8090"))

mcp = FastMCP("searxng-websearch", stateless_http=True, json_response=True)

@mcp.tool()
def web_search(query: str, num_results: int = 5) -> str:
    """Search the web using SearXNG. Returns titles, URLs and snippets for the given query."""
    params = urllib.parse.urlencode({"q": query, "format": "json", "num": num_results})
    url = f"{SEARXNG_URL}/search?{params}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "mcp-websearch/1.0"})
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.loads(r.read())
        results = data.get("results", [])[:num_results]
        if not results:
            return "No results found."
        text = f"Web search results for: {query}\n\n"
        for i, r in enumerate(results, 1):
            snippet = r.get("content", "")[:300]  # cap snippet at 300 chars
            text += f"{i}. {r.get('title','')}\n   URL: {r.get('url','')}\n   {snippet}\n\n"
        return text
    except Exception as e:
        return f"SearXNG error: {e}"

if __name__ == "__main__":
    print(f"MCP web search server starting on http://0.0.0.0:{PORT}", flush=True)
    print(f"SearXNG backend: {SEARXNG_URL}", flush=True)

    # Wrap with CORS middleware so llama.cpp WebUI OPTIONS preflight succeeds
    app = mcp.streamable_http_app()
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["*"],
        expose_headers=["*"],
    )

    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
PYEOF
    ok "MCP server script written"
}

stop_server() {
    if is_running; then
        PID=$(cat "$PID_FILE")
        kill "$PID" 2>/dev/null
        for i in $(seq 1 10); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$PID" 2>/dev/null || true
        rm -f "$PID_FILE"
        ok "MCP web search server stopped (PID $PID)"
    else
        ORPHAN=$(lsof -ti tcp:"$MCP_PORT" 2>/dev/null || true)
        if [ -n "$ORPHAN" ]; then
            kill -9 "$ORPHAN" 2>/dev/null || true
            warn "Killed orphaned process on port $MCP_PORT (PID $ORPHAN)"
        else
            warn "MCP server is not running."
        fi
        rm -f "$PID_FILE"
    fi

    # Stop SearXNG container
    if searxng_running; then
        info "Stopping SearXNG..."
        docker stop searxng >> "$LOG_FILE" 2>&1 && ok "SearXNG stopped"
    fi
}

start_server() {
    if is_running; then
        PID=$(cat "$PID_FILE")
        warn "MCP server already running (PID $PID) on port $MCP_PORT"
        return
    fi

    install_deps
    start_searxng
    write_mcp_server

    echo ""
    echo "========================================"
    echo "  MCP Web Search — Starting"
    echo "========================================"
    info "MCP port    : $MCP_PORT"
    info "SearXNG     : $SEARXNG_URL"
    echo ""

    MCP_PORT="$MCP_PORT" SEARXNG_URL="$SEARXNG_URL" \
    nohup "$PYTHON" "$PROJECT_DIR/.mcp_websearch_server.py" >> "$LOG_FILE" 2>&1 &

    PID=$!
    echo "$PID" > "$PID_FILE"
    info "Launched PID $PID — waiting..."

    for i in $(seq 1 20); do
        if ! kill -0 "$PID" 2>/dev/null; then
            err "Process died. Last log lines:"
            tail -10 "$LOG_FILE"
            rm -f "$PID_FILE"
            exit 1
        fi
        if curl -sf "http://localhost:$MCP_PORT/mcp" &>/dev/null; then
            break
        fi
        sleep 1
        printf "."
    done
    echo ""

    if curl -sf "http://localhost:$MCP_PORT/mcp" &>/dev/null; then
        ok "MCP web search server is UP (PID $PID)"
        echo ""
        echo -e "  MCP URL  : ${CYAN}http://localhost:$MCP_PORT/mcp${NC}"
        echo -e "  SearXNG  : ${CYAN}$SEARXNG_URL${NC}"
        echo ""
        echo -e "  ${BOLD}Add to llama.cpp WebUI:${NC}"
        echo -e "  Open http://localhost:8080 → MCP icon → add http://localhost:$MCP_PORT/mcp"
        echo ""
        echo -e "  Stop     : $0 stop"
        echo -e "  Logs     : $0 logs"
    else
        warn "Server started but not responding yet. Check: $0 logs"
    fi
}

# ── Commands ──────────────────────────────────────────────────────────────────

case "$COMMAND" in
    start)
        start_server
        ;;
    stop)
        echo "========================================"
        echo "  MCP Web Search — Stopping"
        echo "========================================"
        stop_server
        ;;
    restart)
        echo "========================================"
        echo "  MCP Web Search — Restarting"
        echo "========================================"
        stop_server
        sleep 1
        start_server
        ;;
    status)
        if is_running; then
            PID=$(cat "$PID_FILE")
            ok "MCP server is RUNNING (PID $PID) on port $MCP_PORT"
            searxng_running && ok "SearXNG is RUNNING on port $SEARXNG_PORT" || warn "SearXNG is NOT running"
            echo ""
            curl -sf "http://localhost:$MCP_PORT/mcp" &>/dev/null \
                && echo -e "  HTTP: ${GREEN}responding${NC}" \
                || warn "  HTTP: not responding"
        else
            warn "MCP server is NOT running."
            rm -f "$PID_FILE"
        fi
        ;;
    logs)
        exec tail -f "$LOG_FILE"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs} [PORT]"
        echo ""
        echo "  start [PORT]    Start MCP web search server (default port: 8090)"
        echo "  stop            Stop MCP server and SearXNG"
        echo "  restart [PORT]  Restart both"
        echo "  status          Show running status"
        echo "  logs            Tail live logs"
        echo ""
        echo "Examples:"
        echo "  $0 start 8090"
        echo "  $0 start 9000"
        echo "  $0 stop"
        exit 1
        ;;
esac
