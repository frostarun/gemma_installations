# Gemma 4 — Local LLM Server Scripts

Run Google's Gemma 4 locally with full GPU acceleration using llama.cpp.  
Two scripts — pick the one matching your GPU.

---

## All Scripts

| Script | Purpose |
|--------|---------|
| `start-ai.sh` | Start / stop Gemma 4 + MCP web search together |
| `gemma.sh` | Gemma 4 server — RTX 5070 / Blackwell |
| `gemma_2060.sh` | Gemma 4 server — RTX 2060 / Turing (includes install) |
| `llama-cpp-install.sh` | Build llama.cpp with CUDA — RTX 50 series |
| `llama-cpp-install-2060.sh` | Build llama.cpp with CUDA — RTX 20 series |

---

## start-ai.sh — Start Everything at Once

Starts both Gemma 4 and MCP web search with a single command.

```bash
chmod +x start-ai.sh
./start-ai.sh              # start both (MCP on port 8090)
./start-ai.sh start 9000   # start with custom MCP port
./start-ai.sh stop         # stop both
./start-ai.sh restart      # restart both
./start-ai.sh status       # status of both services
./start-ai.sh logs         # tail both logs live
```

Once running:

| Service | URL |
|---------|-----|
| Gemma 4 Web UI | http://localhost:8080 |
| Gemma 4 API (OpenAI) | http://localhost:8080/v1 |
| MCP Web Search | http://localhost:8090/mcp |

> Note: `mcp_websearch.sh` must be in the same directory for `start-ai.sh` to find it.

---

## Which gemma script to use?

| Script | GPU | VRAM | CUDA Arch |
|--------|-----|------|-----------|
| `gemma.sh` | RTX 5070 Laptop (Blackwell) | 8GB | sm_120 |
| `gemma_2060.sh` | RTX 2060 (Turing) | 6GB | sm_75 |

---

## gemma.sh — RTX 5070 / Blackwell

> Assumes CUDA 12.8 and llama.cpp are already installed via `llama-cpp-install.sh`.

### Usage

```bash
chmod +x gemma.sh
./gemma.sh start        # start in background
./gemma.sh stop         # kill the server
./gemma.sh restart      # kill + restart
./gemma.sh status       # GPU VRAM + RAM + health
./gemma.sh logs         # tail live logs
```

### Config (edit top of script)

```bash
MODEL="-hf ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M"   # model + quantization
N_GPU_LAYERS=999    # all layers on GPU (999 = all)
CONTEXT_SIZE=8192   # token context window
PORT=8080           # server port
```

### Endpoints

| Endpoint | URL |
|----------|-----|
| Web UI | http://localhost:8080 |
| OpenAI-compatible API | http://localhost:8080/v1 |
| Chat completions | http://localhost:8080/v1/chat/completions |

### Antigravity Integration

Antigravity accepts any OpenAI-compatible endpoint:

1. Open Antigravity → Settings → Models
2. Select **OpenAI Compatible**
3. Set endpoint: `http://localhost:8080/v1`
4. Model name: `gemma-4-e4b`
5. API key: `none` (leave blank or put any string)

---

## gemma_2060.sh — RTX 2060 / Turing

### First run — install everything

```bash
chmod +x gemma_2060.sh
./gemma_2060.sh install    # installs CUDA 12.6 + builds llama.cpp
source ~/.bashrc
./gemma_2060.sh start
```

### Usage

```bash
./gemma_2060.sh install   # one-time setup
./gemma_2060.sh start
./gemma_2060.sh stop
./gemma_2060.sh restart
./gemma_2060.sh status
./gemma_2060.sh logs
```

### What install does

1. Checks NVIDIA driver (needs >= 520)
2. Installs CUDA 12.6 toolkit (nvcc + cuBLAS + cudart, ~400MB)
3. Clones and builds llama.cpp with `-DCMAKE_CUDA_ARCHITECTURES=75`
4. Verifies binary links against CUDA

### RTX 2060 Model Recommendations

| Quantization | VRAM Used | Quality | Recommended? |
|-------------|-----------|---------|--------------|
| Q4_K_M | ~2.8GB | Good | Yes (default) |
| Q3_K_M | ~2.2GB | Acceptable | If display uses 1GB+ |
| Q8_0 | ~5.5GB | Near-lossless | Risky on 6GB — avoid |

The script auto-detects available VRAM and switches to Q3_K_M if < 5GB detected.

---

## Quantization Guide

```
Q4_K_M = 4-bit quantization, medium quality  ← best balance for 6-8GB VRAM
Q8_0   = 8-bit, near-lossless quality        ← needs 8GB+ VRAM
Q3_K_M = 3-bit, smaller, lower quality       ← fallback for tight VRAM
```

---

## Troubleshooting

**GPU not being used (CPU/RAM spikes only)**
```bash
# Confirm CUDA build
llama-server --version 2>&1 | grep -i cuda
# Should show: CUDA: yes

# Confirm layers offloaded — check logs
./gemma.sh logs | grep "offloading"
```

**OOM / crash on start**
- Switch to a lower quantization (Q4_K_M → Q3_K_M)
- Reduce context: change `CONTEXT_SIZE=4096`
- Close other GPU apps

**Port already in use**
```bash
./gemma.sh stop        # cleans up properly
lsof -ti tcp:8080 | xargs kill -9   # force clear
```

**CUDA not found after install**
```bash
source ~/.bashrc
nvcc --version
```
