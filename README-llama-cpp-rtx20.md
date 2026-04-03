# llama.cpp CUDA Install — RTX 20 Series (Turing)

> Target: RTX 2060 / 2070 / 2080 · CUDA 12.6 · sm_75  
> Script: `llama-cpp-install-2060.sh`  
> Supports: Ubuntu 22.04, Ubuntu 24.04, WSL2

---

## Why CUDA 12.6 (not 12.8)?

RTX 20 series (Turing, sm_75) is fully supported up to CUDA 12.x. CUDA 12.8 introduced Blackwell-specific features that make it harder to install on systems targeting older GPUs. CUDA 12.6 is the stable, recommended version for Turing and provides identical performance for llama.cpp inference.

---

## Requirements

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| NVIDIA Driver | >= 520 (WSL2) / >= 450 (Linux) | Check with `nvidia-smi` |
| CUDA | 12.6 | Installed by this script |
| Disk | 8GB free | ~400MB CUDA + ~3GB build |
| RAM | 8GB+ | 16GB recommended |
| OS | Ubuntu 22.04 LTS preferred | 24.04 works too |

---

## Install

```bash
chmod +x llama-cpp-install-2060.sh
./llama-cpp-install-2060.sh
source ~/.bashrc
```

Total time: **10–20 minutes**.

---

## What it installs

| Component | Version | Purpose |
|-----------|---------|---------|
| cuda-nvcc | 12.6 | CUDA compiler |
| libcublas-dev | 12.6 | GPU matrix operations |
| cuda-cudart-dev | 12.6 | CUDA runtime |
| llama.cpp | latest | Inference binary |

> Minimal install only — not the full CUDA toolkit (~4GB).

---

## What it does, step by step

1. **Detects WSL2 or native Linux** — picks correct CUDA repo
2. **Checks driver version** — warns if too old, suggests fix
3. **Checks VRAM** — warns if < 5GB (tight for Q4_K_M)
4. **Installs build tools** — cmake, ninja, git, libcurl
5. **Adds NVIDIA CUDA 12.6 apt repo**
6. **Installs minimal CUDA** — nvcc + cuBLAS + cudart (~400MB)
7. **Adds CUDA to PATH** in `~/.bashrc`
8. **Clones/updates llama.cpp**
9. **Builds with** `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=75`
10. **Verifies** binary links against CUDA libs

---

## Verify installation

```bash
nvcc --version
# Should show: release 12.6

ls -lh ~/llama.cpp/build/bin/llama-server

ldd ~/llama.cpp/build/bin/llama-server | grep cuda
# Should show libcuda.so and libcublas.so

~/llama.cpp/build/bin/llama-server --version
```

---

## OS Recommendation for Dedicated Server

If you are setting up the RTX 2060 machine as a **dedicated AI server**:

**Recommended: Ubuntu 22.04 LTS Server (minimal install)**

```bash
# During Ubuntu install, select:
# - Ubuntu Server (minimized)
# - No desktop environment
# - OpenSSH server: YES
# - No snap packages

# After install, set up auto-login for the service:
sudo systemctl enable ssh
```

**Why Ubuntu 22.04 over 24.04:**
- CUDA 12.6 drivers are better tested on 22.04
- No `externally-managed-environment` pip issue
- More stable for headless/server use
- Supported until 2027

---

## Setting Up as a Network Server

After install, make Gemma accessible on your local network:

```bash
# 1. Start Gemma (HOST=0.0.0.0 is already set in gemma_2060.sh)
./gemma_2060.sh start

# 2. Open firewall
sudo ufw allow 8080/tcp
sudo ufw enable

# 3. Find your IP
hostname -I | awk '{print $1}'

# 4. Test from another machine
curl http://<YOUR_IP>:8080/v1/models
```

---

## Architecture Reference

| GPU | Architecture | sm | CUDA | Driver (Linux) |
|-----|-----------|----|------|----------------|
| RTX 2060 / 2060 Super | Turing | sm_75 | 12.6 | >= 450 |
| RTX 2070 / 2070 Super | Turing | sm_75 | 12.6 | >= 450 |
| RTX 2080 / 2080 Ti | Turing | sm_75 | 12.6 | >= 450 |

---

## Troubleshooting

**`nvidia-smi not found` on native Ubuntu**
```bash
sudo apt install nvidia-driver-535
sudo reboot
```

**CUDA install hangs / very slow**
- You may have slow connection to NVIDIA servers
- Try at off-peak hours, or use a VPN

**`GGML_CUDA not enabled` in CMake**
```bash
which nvcc           # should return /usr/local/cuda-12.6/bin/nvcc
source ~/.bashrc     # reload PATH
./llama-cpp-install-2060.sh  # re-run
```

**Build fails on RTX 2060 with OOM**
```bash
# Build uses a lot of RAM. Reduce parallel jobs:
cd ~/llama.cpp/build
ninja -j2 llama-server
```

**`ldd` shows no CUDA libs**
- Binary built without CUDA — CMake silently fell back
- Confirm nvcc was found during build: check script output for `[OK] nvcc:`
- Re-run install script after fixing nvcc path

**Driver version too old**
```bash
# Ubuntu 22.04 / 24.04
sudo apt install nvidia-driver-535
sudo reboot

# Check after reboot
nvidia-smi
```
