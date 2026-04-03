# Gemma 4 — RTX 50 Series (Blackwell) Setup Guide

> Target: RTX 5070 / 5080 / 5090 Laptop or Desktop · sm_120 · 8GB+ VRAM  
> Script: `gemma.sh`

---

## Prerequisites

Run `llama-cpp-install.sh` first — it installs CUDA 12.8 and builds llama.cpp.  
See [README-llama-cpp-rtx50.md](README-llama-cpp-rtx50.md).

---

## Quick Start

```bash
chmod +x gemma.sh
./gemma.sh start
```

---

## Commands

```bash
./gemma.sh start      # start Gemma 4 server in background
./gemma.sh stop       # stop the server
./gemma.sh restart    # restart (picks up config changes)
./gemma.sh status     # show GPU VRAM, RAM usage, health
./gemma.sh logs       # tail live server logs
```

---

## Configuration

Edit the top of `gemma.sh`:

```bash
MODEL="-hf ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M"
N_GPU_LAYERS=999      # 999 = all layers on GPU
CONTEXT_SIZE=8192     # token context window
THREADS=4             # CPU threads for non-GPU work
PORT=8080
```

### Model Options for RTX 50 Series

| Model | Quantization | VRAM Used | Quality |
|-------|-------------|-----------|---------|
| Gemma 4 E4B | Q4_K_M | ~2.8GB | Good — default |
| Gemma 4 E4B | Q8_0 | ~5.5GB | Near-lossless |
| Gemma 4 26B MoE | Q4_K_M | ~14GB | Excellent (needs 16GB+ VRAM) |

---

## API Endpoints

Once running, the server exposes:

| Endpoint | URL | Use |
|----------|-----|-----|
| Web UI | http://localhost:8080 | Chat interface |
| OpenAI API | http://localhost:8080/v1 | Antigravity, code editors |
| Chat completions | http://localhost:8080/v1/chat/completions | Direct API calls |
| Models list | http://localhost:8080/v1/models | List loaded model |

---

## Antigravity Integration

Gemma 4 works with Antigravity IDE as a local model via the OpenAI-compatible API:

1. Open **Antigravity → Settings → Models**
2. Click **Add Custom Model**
3. Select **OpenAI Compatible**
4. Base URL: `http://localhost:8080/v1`
5. Model name: `gemma-4-e4b`
6. API Key: `none` (leave blank or enter any string)

Antigravity will now use your local Gemma 4 for all coding tasks — no internet required, fully private.

---

## Verify GPU Is Being Used

```bash
# While server is running:
watch -n 1 nvidia-smi

# Look for:
# VRAM: ~2.8GB used (Q4_K_M) or ~5.5GB (Q8_0)
# GPU Util: spikes to 80-100% during inference
# Token speed: 8-15 tok/s on RTX 5070 Laptop
```

Also check logs:
```bash
./gemma.sh logs | grep "offloaded"
# Should show: offloaded 43/43 layers to GPU
```

---

## Troubleshooting

**Server starts but GPU barely used**
- Confirm llama.cpp was built with CUDA: `llama-server --version | grep CUDA`
- Ensure `-ngl 999` is set (N_GPU_LAYERS=999 in script)
- Check: `./gemma.sh logs | grep "ggml_cuda_init"`

**Context length error from Antigravity**
- Reduce CONTEXT_SIZE to 4096 in gemma.sh, or
- Reduce search results from MCP server

**Health check times out on first start**
- Normal — model downloads from HuggingFace on first run (~2.5GB)
- Subsequent starts are fast (~10–15 seconds)

**Port 8080 already in use**
```bash
lsof -ti tcp:8080 | xargs kill -9
./gemma.sh start
```

---

## Hardware Reference

| GPU | VRAM | Recommended Model | Max Context |
|-----|------|-------------------|-------------|
| RTX 5070 Laptop | 8GB | E4B Q4_K_M | 8K |
| RTX 5070 Ti | 12GB | E4B Q8_0 | 16K |
| RTX 5080 | 16GB | 26B MoE Q4_K_M | 32K |
| RTX 5090 | 32GB | 26B MoE Q8_0 | 64K |
