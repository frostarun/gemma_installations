#!/usr/bin/env bash
# llama-server.sh — Start, stop, restart, and monitor llama-server in background

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$PROJECT_DIR/.llama-server.pid"
LOG_FILE="$PROJECT_DIR/.llama-server.log"

# ── Config — edit these ───────────────────────────────────────────────────────
MODEL="-hf ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M"
N_GPU_LAYERS=999          # Set to 0 if no GPU, or partial (e.g. 20) for limited VRAM
CONTEXT_SIZE=8192         # Lower = faster inference, less RAM
THREADS=4                 # CPU threads for non-GPU layers
HOST="0.0.0.0"
PORT=8080
# ─────────────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] $*${NC}"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] $*${NC}"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

find_binary() {
    # Check common locations for llama-server
    for bin in \
        llama-server \
        "$HOME/llama.cpp/build/bin/llama-server" \
        "/usr/local/bin/llama-server" \
        "/opt/homebrew/bin/llama-server"; do
        if command -v "$bin" &>/dev/null 2>&1 || [ -x "$bin" ]; then
            echo "$bin"
            return 0
        fi
    done
    return 1
}

stop_server() {
    if is_running; then
        PID=$(cat "$PID_FILE")
        kill "$PID" 2>/dev/null
        # Wait up to 5s for clean exit
        for i in $(seq 1 10); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.5
        done
        # Force kill if still alive
        kill -9 "$PID" 2>/dev/null
        rm -f "$PID_FILE"
        ok "Stopped llama-server (PID $PID)"
    else
        # Also catch any orphaned llama-server on our port
        ORPHAN=$(lsof -ti tcp:"$PORT" 2>/dev/null)
        if [ -n "$ORPHAN" ]; then
            kill -9 "$ORPHAN" 2>/dev/null
            warn "Killed orphaned process on port $PORT (PID $ORPHAN)"
        else
            warn "llama-server is not running."
        fi
        rm -f "$PID_FILE"
    fi
}

start_server() {
    if is_running; then
        PID=$(cat "$PID_FILE")
        warn "llama-server already running (PID $PID) — use 'restart' to reload."
        echo -e "  API: ${CYAN}http://localhost:$PORT${NC}"
        return
    fi

    BINARY=$(find_binary)
    if [ -z "$BINARY" ]; then
        err "llama-server not found. Install with:"
        echo "  macOS : brew install llama.cpp"
        echo "  Linux : build from source with GGML_CUDA=ON"
        exit 1
    fi

    echo "========================================"
    echo "  llama-server — Starting"
    echo "========================================"
    log "Binary  : $BINARY"
    log "Model   : $MODEL"
    log "GPU     : $N_GPU_LAYERS layers"
    log "Context : $CONTEXT_SIZE tokens"
    log "Port    : $PORT"
    echo ""

    # Start in background, redirect output to log
    nohup "$BINARY" \
        $MODEL \
        --n-gpu-layers "$N_GPU_LAYERS" \
        --ctx-size "$CONTEXT_SIZE" \
        --threads "$THREADS" \
        --host "$HOST" \
        --port "$PORT" \
        --webui-mcp-proxy \
        >> "$LOG_FILE" 2>&1 &

    PID=$!
    echo "$PID" > "$PID_FILE"
    log "Launched with PID $PID — waiting for server to be ready..."

    # Health check — wait up to 300s (model may need to download first)
    log "Waiting for server (model download + load can take a few minutes)..."
    for i in $(seq 1 300); do
        if ! kill -0 "$PID" 2>/dev/null; then
            err "Process died early. Last 20 lines of log:"
            tail -20 "$LOG_FILE"
            rm -f "$PID_FILE"
            exit 1
        fi
        # Try both /health and / — older builds don't have /health
        if curl -sf "http://localhost:$PORT/" &>/dev/null || \
           curl -sf "http://localhost:$PORT/health" &>/dev/null; then
            break
        fi
        sleep 1
        # Print a dot every 5s to show progress
        [ $(( i % 5 )) -eq 0 ] && printf "." || true
    done
    echo ""

    if curl -sf "http://localhost:$PORT/" &>/dev/null || \
       curl -sf "http://localhost:$PORT/health" &>/dev/null; then
        ok "llama-server is UP (PID $PID)"
        echo ""
        echo -e "  API endpoint : ${CYAN}http://localhost:$PORT/v1${NC}"
        echo -e "  Web UI       : ${CYAN}http://localhost:$PORT${NC}"
        echo -e "  Logs         : tail -f $LOG_FILE"
        echo -e "  Stop         : $0 stop"
        echo -e "  Restart      : $0 restart"
        echo ""
    else
        warn "Server started but health check timed out after 5 minutes."
        warn "It may still be loading — check: curl http://localhost:$PORT/"
        echo "  Logs: tail -f $LOG_FILE"
    fi
}

# ── Commands ──────────────────────────────────────────────────────────────────

case "${1:-start}" in
    start)
        start_server
        ;;

    stop)
        echo "========================================"
        echo "  llama-server — Stopping"
        echo "========================================"
        stop_server
        ;;

    restart)
        echo "========================================"
        echo "  llama-server — Restarting"
        echo "========================================"
        stop_server
        sleep 1
        start_server
        ;;

    status)
        if is_running; then
            PID=$(cat "$PID_FILE")
            ok "llama-server is RUNNING (PID $PID)"
            echo ""
            # Show GPU usage if nvidia-smi available
            if command -v nvidia-smi &>/dev/null; then
                echo "GPU usage:"
                nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
                    --format=csv,noheader,nounits | \
                    awk -F',' '{printf "  %s | VRAM: %sMB / %sMB | GPU: %s%%\n", $1, $2, $3, $4}'
                echo ""
            fi
            # Show RAM used by this process
            RSS_KB=$(cat /proc/$PID/status 2>/dev/null | grep VmRSS | awk '{print $2}')
            RSS_MB=$(( RSS_KB / 1024 ))
            echo -e "  RAM used : ~${RSS_MB}MB"
            echo -e "  API      : http://localhost:$PORT"
            curl -sf "http://localhost:$PORT/" &>/dev/null && echo -e "  Status   : ${GREEN}responding${NC}" || warn "  (not responding yet)"
        else
            warn "llama-server is NOT running."
            rm -f "$PID_FILE"
        fi
        ;;

    logs)
        exec tail -f "$LOG_FILE"
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|status|logs}"
        echo ""
        echo "  start    Start llama-server in background"
        echo "  stop     Stop the running server"
        echo "  restart  Stop and start fresh"
        echo "  status   Show running status + GPU/RAM usage"
        echo "  logs     Tail live server logs"
        exit 1
        ;;
esac
