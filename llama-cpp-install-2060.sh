#!/usr/bin/env bash
# llama-cpp-install-2060.sh
# Installs CUDA 12.6 + builds llama.cpp for RTX 20 series (Turing sm_75)
# Supports: Ubuntu 22.04 / 24.04 (native) and WSL2

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CUDA_VERSION="12-6"
CUDA_PATH="/usr/local/cuda-12.6"
LLAMA_DIR="$HOME/llama.cpp"
GPU_ARCH="75"            # sm_75 = Turing (RTX 2060 / 2070 / 2080)
BUILD_JOBS=$(nproc)
WSL_LIB="/usr/lib/wsl/lib"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

IS_WSL=false
uname -r | grep -qi "microsoft" && IS_WSL=true

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=================================================${NC}"
echo -e "${BOLD}  llama.cpp CUDA Installer${NC}"
echo -e "${BOLD}  RTX 20 Series · Turing sm_75${NC}"
echo -e "${BOLD}  Supports: Ubuntu 22.04 / 24.04 / WSL2${NC}"
echo -e "${BOLD}=================================================${NC}"
echo ""

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
step "Pre-flight checks"

if $IS_WSL; then
    ok "Environment: WSL2"
    if ! command -v nvidia-smi &>/dev/null; then
        if [ -x "$WSL_LIB/nvidia-smi" ]; then
            export PATH="$WSL_LIB:$PATH"
            grep -q "wsl/lib" "$HOME/.bashrc" 2>/dev/null || \
                echo "export PATH=$WSL_LIB:\$PATH" >> "$HOME/.bashrc"
            ok "Found nvidia-smi at $WSL_LIB — added to PATH"
        else
            die "nvidia-smi not found. Install NVIDIA drivers >= 520 on Windows host."
        fi
    fi
    MIN_DRIVER=520
else
    ok "Environment: Native Linux"
    if ! command -v nvidia-smi &>/dev/null; then
        info "nvidia-smi not found — installing NVIDIA driver 535..."
        sudo apt-get install -y nvidia-driver-535 -qq
        die "Driver installed. Reboot and re-run this script."
    fi
    MIN_DRIVER=450
fi

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')
DRIVER_MAJOR=$(echo "$DRIVER_VER" | cut -d. -f1)
ok "GPU: $GPU_NAME | Driver: $DRIVER_VER | VRAM: ${VRAM_MB}MiB"

[ "$DRIVER_MAJOR" -lt "$MIN_DRIVER" ] && \
    die "Driver $DRIVER_VER too old. Need >= $MIN_DRIVER. Run: sudo apt install nvidia-driver-535"
ok "Driver OK ($DRIVER_VER >= $MIN_DRIVER)"

# VRAM warning for tight configs
if [ "$VRAM_MB" -lt 5000 ]; then
    warn "Less than 5GB VRAM (${VRAM_MB}MiB). Will use Q3_K_M model in gemma_2060.sh."
fi

FREE_GB=$(df / | tail -1 | awk '{print int($4/1024/1024)}')
[ "$FREE_GB" -lt 8 ] && die "Only ${FREE_GB}GB free. Need 8GB+."
ok "Disk: ${FREE_GB}GB free"

# ── 2. Build dependencies ─────────────────────────────────────────────────────
step "Installing build dependencies"

sudo apt-get update -qq
sudo apt-get install -y \
    build-essential cmake git wget curl \
    pkg-config libcurl4-openssl-dev \
    ninja-build python3-full lsb-release \
    2>&1 | grep -E "^(Get|Setting|Unpacking)" | head -20 || true
ok "Build dependencies installed"

# ── 3. Install CUDA 12.6 ──────────────────────────────────────────────────────
step "Installing CUDA 12.6 Toolkit (sm_75 compatible — minimal)"

NVCC_CURRENT=$(nvcc --version 2>/dev/null | grep "release" | awk '{print $5}' | tr -d ',' || echo "none")

if nvcc --version 2>/dev/null | grep -q "12.6" && [ -d "$CUDA_PATH" ]; then
    ok "CUDA 12.6 already installed — skipping"
else
    info "Current nvcc: ${NVCC_CURRENT} — installing CUDA 12.6"

    if $IS_WSL; then
        REPO_SLUG="wsl-ubuntu"
    else
        UBUNTU_VER=$(lsb_release -rs 2>/dev/null | tr -d '.' || echo "2204")
        REPO_SLUG="ubuntu${UBUNTU_VER}"
    fi

    KEYRING_DEB="cuda-keyring_1.1-1_all.deb"
    cd /tmp
    wget -q --show-progress \
        "https://developer.download.nvidia.com/compute/cuda/repos/${REPO_SLUG}/x86_64/${KEYRING_DEB}" \
        -O "$KEYRING_DEB"
    sudo dpkg -i "$KEYRING_DEB"
    sudo apt-get update -qq

    info "Installing minimal CUDA components (~400MB)..."
    sudo apt-get install -y \
        "cuda-nvcc-${CUDA_VERSION}" \
        "libcublas-dev-${CUDA_VERSION}" \
        "cuda-cudart-dev-${CUDA_VERSION}" \
        2>&1 | grep -E "^(Get|Setting|Unpacking)" | tail -10 || true

    ok "CUDA 12.6 installed (nvcc + cuBLAS + cudart)"
fi

# ── 4. Configure PATH ─────────────────────────────────────────────────────────
step "Configuring CUDA environment"

if ! grep -q "cuda-12.6" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" << EOF

# CUDA 12.6 — added by llama-cpp-install-2060.sh
export PATH=${CUDA_PATH}/bin:\$PATH
export LD_LIBRARY_PATH=${CUDA_PATH}/lib64:\${LD_LIBRARY_PATH:-}
EOF
    ok "Added CUDA 12.6 paths to ~/.bashrc"
else
    ok "CUDA paths already in ~/.bashrc"
fi

export PATH="${CUDA_PATH}/bin:$PATH"
export LD_LIBRARY_PATH="${CUDA_PATH}/lib64:${LD_LIBRARY_PATH:-}"

NVCC_BIN=$(which nvcc 2>/dev/null || echo "${CUDA_PATH}/bin/nvcc")
[ -x "$NVCC_BIN" ] || die "nvcc not found after install."
NVCC_NEW=$("$NVCC_BIN" --version | grep "release" | awk '{print $5}' | tr -d ',')
ok "nvcc: $NVCC_NEW at $NVCC_BIN"

# ── 5. Build llama.cpp ────────────────────────────────────────────────────────
step "Building llama.cpp with CUDA sm_${GPU_ARCH} (Turing)"

if [ ! -d "$LLAMA_DIR" ]; then
    info "Cloning llama.cpp..."
    git clone https://github.com/ggerganov/llama.cpp "$LLAMA_DIR"
else
    cd "$LLAMA_DIR"
    info "llama.cpp exists — pulling latest"
    if git diff --quiet && git diff --cached --quiet; then
        git pull --ff-only 2>/dev/null && ok "Updated" || warn "Could not pull — using existing source"
    else
        warn "Local changes detected — skipping git pull"
    fi
fi

cd "$LLAMA_DIR"
[ -d "build" ] && rm -rf build
mkdir build && cd build

info "Running CMake (targeting sm_${GPU_ARCH} Turing)..."
cmake .. \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="${GPU_ARCH}" \
    -DCMAKE_CUDA_COMPILER="${CUDA_PATH}/bin/nvcc" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=ON \
    -GNinja \
    2>&1 | grep -E "^(--|CMake|Found|CUDA|GGML)" | head -30

grep -q "GGML_CUDA:BOOL=ON" CMakeCache.txt || die "CMake did not enable GGML_CUDA."
ok "CMake configured — GGML_CUDA=ON, ARCH=sm_${GPU_ARCH}"

info "Compiling with ${BUILD_JOBS} cores (5–15 minutes)..."
ninja -j"$BUILD_JOBS" llama-server 2>&1 | tail -5

BINARY="$LLAMA_DIR/build/bin/llama-server"
[ -x "$BINARY" ] || die "Build failed — binary not found at $BINARY"
ok "Build complete: $BINARY"

ldd "$BINARY" 2>/dev/null | grep -q "libcuda\|libcublas" && \
    ok "Binary links against CUDA libraries" || \
    warn "CUDA libs not in ldd output — verify GPU usage with nvidia-smi after start"

# ── 6. Update gemma_2060.sh if present ───────────────────────────────────────
step "Checking for gemma_2060.sh"

GEMMA_SH="$SCRIPT_DIR/gemma_2060.sh"
if [ -f "$GEMMA_SH" ]; then
    ok "gemma_2060.sh found at $GEMMA_SH — ready to use"
else
    warn "gemma_2060.sh not found at $GEMMA_SH"
fi

# ── 7. Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=================================================${NC}"
echo -e "${BOLD}  Installation Complete${NC}"
echo -e "${BOLD}=================================================${NC}"
echo ""
echo -e "  GPU      : $GPU_NAME"
echo -e "  VRAM     : ${VRAM_MB}MiB"
echo -e "  CUDA     : 12.6 sm_${GPU_ARCH} Turing"
echo -e "  Binary   : $BINARY"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "    source ~/.bashrc"
echo -e "    ./gemma_2060.sh start"
echo ""
echo -e "  ${BOLD}Verify GPU:${NC}"
echo -e "    watch -n 1 nvidia-smi"
echo -e "    # VRAM should jump to ~2.8GB on start"
echo ""
