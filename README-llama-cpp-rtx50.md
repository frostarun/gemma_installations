# llama.cpp CUDA Install — RTX 50 Series (Blackwell)

> Target: RTX 5070 / 5080 / 5090 · CUDA 12.8 · sm_120  
> Script: `llama-cpp-install.sh`  
> Supports: Ubuntu 22.04, Ubuntu 24.04, WSL2

---

## Why a custom build?

The `brew install llama.cpp` / `apt install llama.cpp` packages are compiled **without CUDA** — the model runs on CPU only. This script builds llama.cpp from source with CUDA enabled, targeting the Blackwell architecture (sm_120) for maximum GPU utilization.

---

## Requirements

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| NVIDIA Driver | >= 570 (WSL2) / >= 525 (Linux) | Check with `nvidia-smi` |
| CUDA | 12.8 | Installed by this script |
| Disk | 8GB free | CUDA ~400MB + llama.cpp build ~3GB |
| RAM | 16GB+ | Build process is memory intensive |
| OS | Ubuntu 22.04 / 24.04 / WSL2 | Debian-based only |

---

## Install

```bash
chmod +x llama-cpp-install.sh
./llama-cpp-install.sh
source ~/.bashrc   # load CUDA paths into current terminal
```

Total time: **10–20 minutes** (mostly compilation).

---

## What it installs

| Component | Version | Size | Purpose |
|-----------|---------|------|---------|
| cuda-nvcc | 12.8 | ~50MB | CUDA compiler |
| libcublas-dev | 12.8 | ~300MB | GPU matrix math |
| cuda-cudart-dev | 12.8 | ~10MB | CUDA runtime |
| llama.cpp | latest | ~3GB build | Inference binary |

> Installs **minimal** CUDA components only — not the full 4GB toolkit.

---

## What it does, step by step

1. **Detects environment** — WSL2 or native Linux, sets correct CUDA repo
2. **Checks NVIDIA driver** — exits early with clear message if too old
3. **Installs build tools** — cmake, ninja, git, libcurl
4. **Adds NVIDIA CUDA apt repo** — official NVIDIA keyring
5. **Installs CUDA 12.8** — nvcc + cuBLAS + cudart only
6. **Adds CUDA to PATH** — persists in `~/.bashrc`
7. **Clones/updates llama.cpp** — from github.com/ggml-org/llama.cpp
8. **Builds with CMake + Ninja** — `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120`
9. **Verifies build** — checks binary links against CUDA libs
10. **Updates gemma.sh** — sets model to Q4_K_M if Q8_0 was set

---

## Verify installation

```bash
# Check nvcc version
nvcc --version
# Should show: release 12.8

# Check binary exists
ls -lh ~/llama.cpp/build/bin/llama-server

# Check CUDA linkage
ldd ~/llama.cpp/build/bin/llama-server | grep cuda
# Should show: libcuda.so, libcublas.so

# Run a quick test
~/llama.cpp/build/bin/llama-server --version
```

---

## Architecture Reference

| GPU Family | Architecture | CUDA Arch Flag | Min Driver |
|------------|-------------|----------------|------------|
| RTX 5000 series | Blackwell | `sm_120` | 570 (WSL2) |
| RTX 4000 series | Ada Lovelace | `sm_89` | 520 |
| RTX 3000 series | Ampere | `sm_86` | 450 |
| RTX 2000 series | Turing | `sm_75` | 450 |

---

## Troubleshooting

**Stuck on "Installing cuda-toolkit" for more than 10 minutes**
- Script installs minimal packages only — should be ~5 minutes max
- Check internet speed: `curl -I https://developer.download.nvidia.com`

**`nvcc: command not found` after install**
```bash
source ~/.bashrc
# or manually:
export PATH=/usr/local/cuda-12.8/bin:$PATH
```

**CMake error: `GGML_CUDA not enabled`**
- nvcc path mismatch — check: `which nvcc` vs `CUDA_PATH` in script
- Try: `ls /usr/local/cuda-12.8/bin/nvcc`

**Build fails with OOM**
```bash
# Reduce parallel jobs
ninja -j2 llama-server   # instead of all cores
```

**Driver too old error**
```bash
# Native Ubuntu
sudo apt install nvidia-driver-560
sudo reboot

# WSL2 — update the driver on Windows host
# Download from: https://www.nvidia.com/drivers
```
