#!/usr/bin/env bash
# gemma_2060.sh — Gemma 4 llama-server for RTX 2060 (Turing sm_75, 6GB VRAM)
# Includes: CUDA 12.x install + llama.cpp build + server management

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$PROJECT_DIR/.llama-server.pid"
LOG_FILE="$PROJECT_DIR/.llama-server.log"

# ── Config ────────────────────────────────────────────────────────────────────
# RTX 2060 has 6GB VRAM. Q4_K_M of E4B = ~2.8GB — fits safely.
# DO NOT use Q8_0 — it needs ~5.5GB + display overhead = OOM on 6GB.
MODEL="-hf ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M"
N_GPU_LAYERS=999
CONTEXT_SIZE=8192
THREADS=4
HOST="0.0.0.0"
PORT=8080

# Build config
CUDA_VERSION="12-6"                  # CUDA 12.6 — latest that works on sm_75
CUDA_PATH="/usr/local/cuda-12.6"
GPU_ARCH="75"                        # sm_75 = Turing (RTX 2060/2070/2080)
LLAMA_DIR="$HOME/llama.cpp"
BUILD_JOBS=$(nproc)
WSL_LIB="/usr/lib/wsl/lib"
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
log()  { echo -e "[$(date '+%H:%M:%S')] $*"; }
die()  { err "$*"; exit 1; }

# ── Install ───────────────────────────────────────────────────────────────────

install() {
    echo ""
    echo -e "${BOLD}=================================================${NC}"
    echo -e "${BOLD}  Gemma 4 Installer — RTX 2060 (sm_75 Turing)${NC}"
    echo -e "${BOLD}=================================================${NC}"
    echo ""

    step "Pre-flight checks"

    # nvidia-smi — native Linux or WSL2
    if ! command -v nvidia-smi &>/dev/null; then
        if [ -x "$WSL_LIB/nvidia-smi" ]; then
            export PATH="$WSL_LIB:$PATH"
            grep -q "wsl/lib" "$HOME/.bashrc" 2>/dev/null || echo "export PATH=$WSL_LIB:\$PATH" >> "$HOME/.bashrc"
            ok "Found nvidia-smi at $WSL_LIB"
        else
            die "nvidia-smi not found. Install NVIDIA drivers (>= 520) first."
        fi
    fi

    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    DRIVER_MAJOR=$(echo "$DRIVER_VER" | cut -d. -f1)
    ok "GPU: $GPU_NAME | VRAM: ${VRAM_MB}MiB | Driver: $DRIVER_VER"

    if [ "$DRIVER_MAJOR" -lt 520 ]; then
        die "Driver $DRIVER_VER too old for CUDA 12.x. Need >= 520. Run: sudo apt install nvidia-driver-535"
    fi
    ok "Driver OK"

    if [ "$VRAM_MB" -lt 5000 ]; then
        warn "Less than 5GB VRAM detected (${VRAM_MB}MiB). Switching to Q3_K_M model for safety."
        MODEL="-hf ggml-org/gemma-4-E4B-it-GGUF:Q3_K_M"
    fi

    FREE_GB=$(df / | tail -1 | awk '{print int($4/1024/1024)}')
    [ "$FREE_GB" -lt 8 ] && die "Only ${FREE_GB}GB free. Need 8GB+ for CUDA + build."
    ok "Disk: ${FREE_GB}GB free"

    step "Installing build dependencies"
    sudo apt-get update -qq
    sudo apt-get install -y build-essential cmake git wget curl pkg-config \
        libcurl4-openssl-dev ninja-build python3-full -qq
    ok "Build deps installed"

    step "Installing CUDA ${CUDA_VERSION} toolkit (sm_75 compatible)"

    NVCC_VER=$(nvcc --version 2>/dev/null | grep "release" | awk '{print $5}' | tr -d ',' || echo "none")
    if echo "$NVCC_VER" | grep -q "^12\." && [ -d "$CUDA_PATH" ]; then
        ok "CUDA 12.x already installed ($NVCC_VER) — skipping"
    else
        # Detect if native Ubuntu or WSL2
        if uname -r | grep -qi "microsoft"; then
            REPO_SLUG="wsl-ubuntu"
        else
            UBUNTU_VER=$(lsb_release -rs | tr -d '.')
            REPO_SLUG="ubuntu${UBUNTU_VER}"
        fi

        KEYRING_DEB="cuda-keyring_1.1-1_all.deb"
        KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${REPO_SLUG}/x86_64/$KEYRING_DEB"
        cd /tmp
        wget -q --show-progress "$KEYRING_URL" -O "$KEYRING_DEB"
        sudo dpkg -i "$KEYRING_DEB"
        sudo apt-get update -qq
        info "Installing cuda-nvcc, libcublas-dev, cuda-cudart-dev (~400MB)..."
        sudo apt-get install -y \
            "cuda-nvcc-${CUDA_VERSION}" \
            "libcublas-dev-${CUDA_VERSION}" \
            "cuda-cudart-dev-${CUDA_VERSION}" -qq
        ok "CUDA ${CUDA_VERSION} installed"
    fi

    # PATH
    grep -q "cuda-12" "$HOME/.bashrc" 2>/dev/null || \
        echo -e "\nexport PATH=${CUDA_PATH}/bin:\$PATH\nexport LD_LIBRARY_PATH=${CUDA_PATH}/lib64:\${LD_LIBRARY_PATH:-}" >> "$HOME/.bashrc"
    export PATH="${CUDA_PATH}/bin:$PATH"
    export LD_LIBRARY_PATH="${CUDA_PATH}/lib64:${LD_LIBRARY_PATH:-}"

    NVCC_BIN=$(which nvcc 2>/dev/null || echo "${CUDA_PATH}/bin/nvcc")
    [ -x "$NVCC_BIN" ] || die "nvcc not found after install. Check: ls $CUDA_PATH/bin/"
    ok "nvcc: $("$NVCC_BIN" --version | grep release | awk '{print $5}' | tr -d ',')"

    step "Building llama.cpp with CUDA sm_${GPU_ARCH} (RTX 2060)"

    if [ ! -d "$LLAMA_DIR" ]; then
        git clone https://github.com/ggerganov/llama.cpp "$LLAMA_DIR"
    else
        cd "$LLAMA_DIR"
        git diff --quiet && git diff --cached --quiet && \
            git pull --ff-only 2>/dev/null && ok "llama.cpp updated" || \
            warn "Skipping git pull — local changes detected"
    fi

    cd "$LLAMA_DIR"
    rm -rf build && mkdir build && cd build

    cmake .. \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${GPU_ARCH}" \
        -DCMAKE_CUDA_COMPILER="${CUDA_PATH}/bin/nvcc" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_CURL=ON \
        -GNinja 2>&1 | grep -E "^(--|CMake|Found|CUDA|GGML)" | head -20

    grep -q "GGML_CUDA:BOOL=ON" CMakeCache.txt || die "CMake did not enable GGML_CUDA. Check nvcc path."
    ok "CMake configured — GGML_CUDA=ON, ARCH=sm_${GPU_ARCH}"

    info "Compiling with ${BUILD_JOBS} cores..."
    ninja -j"$BUILD_JOBS" llama-server 2>&1 | tail -5

    BINARY="$LLAMA_DIR/build/bin/llama-server"
    [ -x "$BINARY" ] || die "Build failed — binary not found at $BINARY"
    ok "Build complete: $BINARY"

    echo ""
    echo -e "${BOLD}=================================================${NC}"
    echo -e "${BOLD}  Installation Complete${NC}"
    echo -e "${BOLD}=================================================${NC}"
    echo ""
    echo -e "  GPU    : $GPU_NAME"
    echo -e "  VRAM   : ${VRAM_MB}MiB"
    echo -e "  Binary : $BINARY"
    echo -e "  Model  : $MODEL"
    echo ""
    echo -e "  Run: ${CYAN}source ~/.bashrc && ./gemma_2060.sh start${NC}"
    echo ""
}

# ── Server helpers ────────────────────────────────────────────────────────────

is_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

find_binary() {
    for bin in \
        "$HOME/llama.cpp/build/bin/llama-server" \
        llama-server \
        "/usr/local/bin/llama-server"; do
        command -v "$bin" &>/dev/null 2>&1 || [ -x "$bin" ] && echo "$bin" && return 0
    done
    return 1
}

stop_server() {
    if is_running; then
        PID=$(cat "$PID_FILE")
        kill "$PID" 2>/dev/null
        for i in $(seq 1 10); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
        kill -9 "$PID" 2>/dev/null || true
        rm -f "$PID_FILE"
        ok "Stopped llama-server (PID $PID)"
    else
        ORPHAN=$(lsof -ti tcp:"$PORT" 2>/dev/null || true)
        [ -n "$ORPHAN" ] && kill -9 "$ORPHAN" 2>/dev/null && warn "Killed orphan on port $PORT"
        rm -f "$PID_FILE"
        warn "llama-server was not running."
    fi
}

start_server() {
    is_running && warn "Already running (PID $(cat "$PID_FILE")) — use restart." && return

    BINARY=$(find_binary) || die "llama-server not found. Run: ./gemma_2060.sh install"

    echo "========================================"
    echo "  Gemma 4 — Starting (RTX 2060)"
    echo "========================================"
    log "Binary  : $BINARY"
    log "Model   : $MODEL"
    log "GPU     : $N_GPU_LAYERS layers"
    log "Context : $CONTEXT_SIZE tokens"
    log "Port    : $PORT"
    echo ""

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
    log "Launched PID $PID — waiting for server..."

    for i in $(seq 1 300); do
        ! kill -0 "$PID" 2>/dev/null && \
            err "Process died early:" && tail -20 "$LOG_FILE" && rm -f "$PID_FILE" && exit 1
        { curl -sf "http://localhost:$PORT/" &>/dev/null || \
          curl -sf "http://localhost:$PORT/health" &>/dev/null; } && break
        sleep 1
        [ $(( i % 5 )) -eq 0 ] && printf "." || true
    done
    echo ""

    if curl -sf "http://localhost:$PORT/" &>/dev/null || curl -sf "http://localhost:$PORT/health" &>/dev/null; then
        ok "llama-server is UP (PID $PID)"
        echo ""
        echo -e "  Web UI       : ${CYAN}http://localhost:$PORT${NC}"
        echo -e "  API (OpenAI) : ${CYAN}http://localhost:$PORT/v1${NC}"
        echo -e "  Logs         : $0 logs"
        echo ""
    else
        warn "Started but health check timed out. Check: $0 logs"
    fi
}

# ── Commands ──────────────────────────────────────────────────────────────────

case "${1:-start}" in
    install)  install ;;
    start)    start_server ;;
    stop)
        echo "========================================"
        echo "  Gemma 4 — Stopping"
        echo "========================================"
        stop_server
        ;;
    restart)
        echo "========================================"
        echo "  Gemma 4 — Restarting"
        echo "========================================"
        stop_server; sleep 1; start_server
        ;;
    status)
        if is_running; then
            PID=$(cat "$PID_FILE")
            ok "llama-server RUNNING (PID $PID)"
            command -v nvidia-smi &>/dev/null && \
                nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
                --format=csv,noheader,nounits | \
                awk -F',' '{printf "  %s | VRAM: %sMB / %sMB | GPU: %s%%\n",$1,$2,$3,$4}'
            RSS_KB=$(grep VmRSS /proc/$PID/status 2>/dev/null | awk '{print $2}')
            echo -e "  RAM: ~$(( RSS_KB / 1024 ))MB | API: http://localhost:$PORT"
        else
            warn "llama-server is NOT running."; rm -f "$PID_FILE"
        fi
        ;;
    logs)  exec tail -f "$LOG_FILE" ;;
    *)
        echo "Usage: $0 {install|start|stop|restart|status|logs}"
        echo ""
        echo "  install   Install CUDA + build llama.cpp (run once)"
        echo "  start     Start server in background"
        echo "  stop      Stop server"
        echo "  restart   Restart server"
        echo "  status    Show GPU/RAM/status"
        echo "  logs      Tail live logs"
        exit 1
        ;;
esac
