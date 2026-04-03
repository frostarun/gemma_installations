# Gemma 4 — RTX 20 Series (Turing) Setup Guide

> Target: RTX 2060 / 2070 / 2080 · sm_75 · 6–11GB VRAM  
> Script: `gemma_2060.sh`

---

## OS Recommendation

**Use Ubuntu 22.04 LTS** (not 24.04) for a server/headless setup:

| | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |
|--|--|--|
| CUDA driver compat | Excellent | Good |
| Python pip | Works normally | Blocks system pip |
| Server stability | Battle-tested | Still stabilising |
| Support until | 2027 | 2029 |
| Recommended | Yes | Not for this use case |

---

## Quick Start

```bash
chmod +x gemma_2060.sh

# First time only — installs CUDA + builds llama.cpp
./gemma_2060.sh install

source ~/.bashrc
./gemma_2060.sh start
```

---

## Commands

```bash
./gemma_2060.sh install   # one-time: install CUDA + build llama.cpp
./gemma_2060.sh start     # start server in background
./gemma_2060.sh stop      # stop server
./gemma_2060.sh restart   # restart (picks up config changes)
./gemma_2060.sh status    # GPU VRAM, RAM, health check
./gemma_2060.sh logs      # tail live server logs
```

---

## Configuration

Edit the top of `gemma_2060.sh`:

```bash
MODEL="-hf ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M"
N_GPU_LAYERS=999
CONTEXT_SIZE=8192
PORT=8080
```

### Model Recommendations for RTX 20 Series

| GPU | VRAM | Recommended Model | VRAM Used | Safe? |
|-----|------|-------------------|-----------|-------|
| RTX 2060 | 6GB | E4B Q4_K_M | ~2.8GB | Yes |
| RTX 2060 | 6GB | E4B Q8_0 | ~5.5GB | Risky |
| RTX 2060 Super | 8GB | E4B Q8_0 | ~5.5GB | Yes |
| RTX 2070 | 8GB | E4B Q8_0 | ~5.5GB | Yes |
| RTX 2080 Ti | 11GB | 26B MoE Q4_K_M | ~10GB | Yes |

> The script auto-detects VRAM and switches to Q3_K_M if < 5GB available.

---

## API Endpoints

| Endpoint | URL | Use |
|----------|-----|-----|
| Web UI | http://localhost:8080 | Chat interface |
| OpenAI API | http://localhost:8080/v1 | Antigravity, code editors |
| Chat completions | http://localhost:8080/v1/chat/completions | Direct calls |

---

## Antigravity Integration

1. Open **Antigravity → Settings → Models**
2. Click **Add Custom Model → OpenAI Compatible**
3. Base URL: `http://localhost:8080/v1`
4. Model name: `gemma-4-e4b`
5. API Key: leave blank

If the server is on a separate machine (e.g. this RTX 2060 as a dedicated server):

```bash
# Replace localhost with the server's IP
Base URL: http://192.168.1.100:8080/v1
```

---

## Using as a Dedicated Server

If installing Ubuntu 22.04 headless on the RTX 2060 machine:

```bash
# 1. Enable auto-start on boot
crontab -e
# Add this line:
@reboot /path/to/gemma_2060.sh start

# 2. Allow connections from other machines
# gemma_2060.sh already sets HOST="0.0.0.0"

# 3. Check IP
ip addr show | grep "inet "

# 4. Connect from another machine:
curl http://<SERVER_IP>:8080/v1/models
```

---

## Verify GPU Is Being Used

```bash
watch -n 1 nvidia-smi

# Expect:
# VRAM: ~2.8GB used
# GPU Util: 70–95% during inference
# Token speed: 5–10 tok/s
```

```bash
./gemma_2060.sh logs | grep "offloaded"
# Should show: offloaded 43/43 layers to GPU
```

---

## Troubleshooting

**GPU barely used (CPU spikes instead)**
- llama.cpp was built without CUDA — run `./gemma_2060.sh install` to rebuild
- Check: `~/llama.cpp/build/bin/llama-server --version | grep CUDA`

**OOM crash on start (RTX 2060 6GB)**
```bash
# Switch to Q3_K_M in gemma_2060.sh:
MODEL="-hf ggml-org/gemma-4-E4B-it-GGUF:Q3_K_M"
# And reduce context:
CONTEXT_SIZE=4096
./gemma_2060.sh restart
```

**Cannot connect from another machine**
```bash
# Check firewall
sudo ufw allow 8080
sudo ufw status
```

**Slow inference (~1 tok/s)**
- Means CPU fallback — GPU not being used
- Rebuild llama.cpp: `./gemma_2060.sh install`
