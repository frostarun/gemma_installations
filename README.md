# Claude Code × Gemma 4 — Local AI Development Stack

Run **Claude Code** entirely offline using Google's **Gemma 4** as the backend model.  
No Anthropic API key required. All inference runs on your local GPU.

```
Claude Code  →  Anthropic proxy  →  Gemma 4 (llama-server)
                    :8081                    :8080
```

---

## Architecture

| Component | Role |
|-----------|------|
| `gemma.sh` / `gemma_2060.sh` | Runs Gemma 4 via llama-server (OpenAI-compatible API) |
| `anthropic_proxy.py` | Translates Anthropic `/v1/messages` ↔ OpenAI `/v1/chat/completions` |
| `mcp_websearch.sh` | Free web search via SearXNG + FastMCP (no API key needed) |
| `start-ai.sh` | Starts/stops all three services together |
| `claude-code-gemma.sh` | Launches Claude Code pointed at the local stack |

---

## All Scripts

| Script | Purpose |
|--------|---------|
| `start-ai.sh` | Start / stop / restart all AI services |
| `claude-code-gemma.sh` | Launch Claude Code with Gemma backend |
| `anthropic_proxy.py` | Anthropic→OpenAI API proxy (started by start-ai.sh) |
| `gemma.sh` | Gemma 4 server — RTX 5070 / Blackwell |
| `gemma_2060.sh` | Gemma 4 server — RTX 2060 / Turing |
| `mcp_websearch.sh` | Free web search MCP server |
| `llama-cpp-install.sh` | Build llama.cpp with CUDA — RTX 50 series |
| `llama-cpp-install-2060.sh` | Build llama.cpp with CUDA — RTX 20 series |

---

## Prerequisites

### 1. Hardware

| GPU | Script |
|-----|--------|
| RTX 5070 / Blackwell (VRAM ≥ 8GB) | `gemma.sh` |
| RTX 2060 / Turing (VRAM ≥ 6GB) | `gemma_2060.sh` |

### 2. NVIDIA Drivers + CUDA

**RTX 50 series (WSL2 / Linux)**
```bash
chmod +x llama-cpp-install.sh
./llama-cpp-install.sh        # Installs CUDA 12.8 + builds llama.cpp
source ~/.bashrc
```

**RTX 20 series**
```bash
chmod +x llama-cpp-install-2060.sh
./llama-cpp-install-2060.sh install
source ~/.bashrc
```

### 3. Node.js ≥ 20

```bash
# Ubuntu/Debian
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

### 4. Claude Code Source Build

Claude Code must be built from source so it can be pointed at a custom API endpoint.

```bash
# Clone the Claude Code source
git clone https://github.com/anthropics/claude-code ~/projects/claude-code-source-build
cd ~/projects/claude-code-source-build

# Install dependencies
npm install

# Build
node scripts/build-cli.mjs
```

After building, verify:
```bash
node ~/projects/claude-code-source-build/dist/cli.js --version
```

> **Note:** The built binary at `dist/cli.js` must exist before running `claude-code-gemma.sh`.
> If you cloned to a different path, set: `export CLAUDE_CODE_DIR=/your/path`

### 5. Docker (for MCP web search)

```bash
# Install Docker
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER   # add yourself to docker group
newgrp docker                    # apply group change (or log out/in)
```

---

## Quick Start

### First time setup

```bash
git clone https://github.com/yourusername/gemma_installations
cd gemma_installations

# 1. Install CUDA + build llama.cpp (RTX 5070)
./llama-cpp-install.sh && source ~/.bashrc

# 2. Start web search MCP (also creates the Python venv)
chmod +x mcp_websearch.sh
./mcp_websearch.sh start

# 3. Build Claude Code from source (see Prerequisites §4)

# 4. Launch everything
chmod +x claude-code-gemma.sh
./claude-code-gemma.sh
```

### Daily use

```bash
# Start Claude Code (auto-starts backend if not running)
./claude-code-gemma.sh

# Or manage backend separately:
./start-ai.sh start     # start Gemma + MCP + proxy
./start-ai.sh stop      # stop all
./start-ai.sh status    # check all services
./start-ai.sh logs      # tail all logs live
```

---

## start-ai.sh — Manage All Services

```bash
./start-ai.sh start          # start Gemma 4 + MCP + proxy (MCP on port 8090)
./start-ai.sh start 9000     # start with custom MCP port
./start-ai.sh stop           # stop all services
./start-ai.sh restart        # restart all services
./start-ai.sh status         # status of all three services
./start-ai.sh logs           # tail all three logs live
```

**Environment variables (optional):**
```bash
PROXY_PORT=8081   # Anthropic→OpenAI proxy port (default: 8081)
LLAMA_PORT=8080   # Gemma/llama-server port (default: 8080)
```

Once running:

| Service | URL |
|---------|-----|
| Gemma 4 Web UI | http://localhost:8080 |
| Gemma 4 API (OpenAI) | http://localhost:8080/v1 |
| Anthropic Proxy | http://localhost:8081 |
| MCP Web Search | http://localhost:8090/mcp |

---

## claude-code-gemma.sh — Launch Claude Code

```bash
./claude-code-gemma.sh           # launch (auto-starts backend if needed)
./claude-code-gemma.sh --help    # Claude Code flags passed through
```

**Environment variables:**
```bash
CLAUDE_CODE_DIR=~/projects/claude-code-source-build  # path to Claude Code build
PROXY_PORT=8081                                        # proxy port
LLAMA_PORT=8080                                        # Gemma port
```

**What it does automatically:**
1. Checks if Gemma + proxy are running — starts them if not
2. Creates `~/.claude-gemma/settings.json` with broad permissions (first run only)
3. Sets `CLAUDE_CONFIG_DIR=~/.claude-gemma` so config is separate from your real Claude Code
4. Launches Claude Code pointed at the local Gemma backend

---

## Claude Code Settings & Permissions

Claude Code uses `~/.claude-gemma/` as its config directory (isolated from real Claude).

The file `~/.claude-gemma/settings.json` is auto-created on first run with these permissions pre-approved:

```json
{
  "permissions": {
    "allow": [
      "Read(/home/**)",
      "Read(/tmp/**)",
      "Read(/usr/**)",
      "Bash(ls:*)",
      "Bash(git:*)",
      "Bash(npm:*)",
      "Bash(python3:*)",
      "Bash(curl:*)",
      "Bash(docker:*)",
      "Bash(sudo:*)",
      "..."
    ]
  }
}
```

**Why broad permissions?** Gemma runs locally — no data leaves your machine.  
Broad permissions mean fewer interruptions asking you to approve tool calls.

**To add more permissions**, edit `~/.claude-gemma/settings.json` directly.

> **Important:** The bundled `rg` (ripgrep) binary needs execute permission:
> ```bash
> chmod +x ~/projects/claude-code-source-build/dist/cli.bundle/src/entrypoints/vendor/ripgrep/x64-linux/rg
> ```
> Run this once after building Claude Code. Without it, Glob and Grep tools will fail.

---

## GPU Selection

### RTX 5070 (default)

```bash
./gemma.sh start
```

Config at top of `gemma.sh`:
```bash
MODEL="-hf ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M"
N_GPU_LAYERS=999      # all layers on GPU
CONTEXT_SIZE=32768    # 32k context (needed for Gemma 4's thinking model)
PORT=8080
```

### RTX 2060

```bash
./gemma_2060.sh start
```

The script auto-detects available VRAM and picks Q4_K_M or Q3_K_M quantization.

---

## Quantization Guide

```
Q4_K_M  = 4-bit, ~2.8GB VRAM   ← default, best balance
Q8_0    = 8-bit, ~5.5GB VRAM   ← near-lossless, needs 8GB+
Q3_K_M  = 3-bit, ~2.2GB VRAM   ← fallback for tight VRAM
```

---

## MCP Web Search (Free, No API Key)

`mcp_websearch.sh` sets up a self-hosted search stack:
- **SearXNG** — privacy-respecting meta search engine (Docker)
- **FastMCP** bridge — exposes SearXNG as an MCP tool

```bash
./mcp_websearch.sh start 8090   # start (default port 8090)
./mcp_websearch.sh stop
./mcp_websearch.sh status
./mcp_websearch.sh logs
```

Claude Code automatically gets a `web_search` tool when MCP is running.

---

## How the Anthropic Proxy Works

Claude Code's SDK speaks Anthropic format (`/v1/messages`).  
Gemma's llama-server speaks OpenAI format (`/v1/chat/completions`).

`anthropic_proxy.py` bridges them:
- Translates message formats including tool use / tool results
- Multiplies `max_tokens` × 3 to give Gemma's thinking phase enough room
- Falls back to `reasoning_content` if `content` is empty

---

## Troubleshooting

**EACCES on Glob / Grep tools**
```bash
chmod +x ~/projects/claude-code-source-build/dist/cli.bundle/src/entrypoints/vendor/ripgrep/x64-linux/rg
```

**Gemma returns empty responses**
- Increase `CONTEXT_SIZE` to 32768 in `gemma.sh` (needed for thinking model)
- Proxy auto-multiplies max_tokens; if still empty, check: `tail -f .proxy.log`

**GPU not being used (CPU/RAM spikes only)**
```bash
llama-server --version 2>&1 | grep -i cuda   # should show: CUDA: yes
```
If no CUDA, rebuild llama.cpp: `./llama-cpp-install.sh`

**OOM / crash on start**
- Switch quantization: edit `MODEL` in `gemma.sh` from `Q4_K_M` to `Q3_K_M`
- Reduce context: `CONTEXT_SIZE=8192`

**Docker permission denied**
```bash
sudo chmod 666 /var/run/docker.sock   # temporary fix
sudo usermod -aG docker $USER         # permanent fix (requires re-login)
```

**Port already in use**
```bash
./start-ai.sh stop     # cleanly stops all services
./start-ai.sh start
```

**Proxy not starting**
```bash
tail -20 .proxy.log    # check proxy logs
./mcp_websearch.sh start   # ensure Python venv exists first
```

---

## File Structure

```
gemma_installations/
├── claude-code-gemma.sh      ← entry point: launch Claude Code
├── start-ai.sh               ← manage all backend services
├── anthropic_proxy.py        ← Anthropic↔OpenAI API bridge
├── mcp_websearch.sh          ← free web search MCP server
├── gemma.sh                  ← Gemma 4 server (RTX 5070)
├── gemma_2060.sh             ← Gemma 4 server (RTX 2060)
├── llama-cpp-install.sh      ← CUDA + llama.cpp install (RTX 50xx)
└── llama-cpp-install-2060.sh ← CUDA + llama.cpp install (RTX 20xx)

Runtime files (created automatically, gitignored):
├── .mcp-venv/                ← Python venv for proxy + MCP
├── .proxy.pid                ← proxy process ID
├── .proxy.log                ← proxy logs
├── .llama-server.pid         ← Gemma process ID
├── .llama-server.log         ← Gemma logs
└── .mcp-websearch.log        ← MCP logs

User config (created automatically):
└── ~/.claude-gemma/
    └── settings.json         ← Claude Code permissions for Gemma sessions
```
