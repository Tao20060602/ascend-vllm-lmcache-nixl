#!/usr/bin/env bash
# A 臂 CPU 档安装 v2:基于 /usr/bin/python3.12(Ubuntu 官方真身)的独立 venv
# v1 失败结论(留档进报告):本镜像把 /usr/bin/python3 软链改指 /opt/buildtools/python-3.12.9,
# 该解释器的 _ctypes 扩展损坏(undefined symbol: _PyErr_SetLocaleString),任何源码构建必失败。
# 修复动作:sudo apt-get install --reinstall python3.12-minimal 恢复真身 + 安装 python3.12-venv;
# 本脚本全部安装进 venv,与镜像默认 Python 完全隔离。若换新环境重跑,先执行本脚本第 0 步自检。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

PIP_INDEX_URL="${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
PYTORCH_INDEX="https://download.pytorch.org/whl/cpu/"
export PIP_INDEX_URL
WORKROOT="${WORKROOT:-$HOME/ascend-stack}"
RUNDIR="$SCRIPT_DIR/../run"
mkdir -p "$WORKROOT" "$RUNDIR"
# aarch64 源码编译 C++ 较重,限制并行度防内存耗尽(30 GiB 内存环境取 8)
export MAX_JOBS="${MAX_JOBS:-8}"
PYBIN=/usr/bin/python3.12

echo "==> [0/6] 前置自检:真身 Python 与 venv"
if ! "$PYBIN" -c "import ctypes" 2>/dev/null; then
  echo "[错误] /usr/bin/python3.12 的 ctypes 异常(镜像软链劫持未修复)。" >&2
  echo "       修复:sudo apt-get update && sudo apt-get install --reinstall -y python3.12-minimal" >&2
  exit 1
fi
VENV="${VENV:-$HOME/venv-vllm-cpu}"
"$PYBIN" -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -c "import ctypes,sys; print('venv ctypes OK, Python', sys.version.split()[0])"
# tcmalloc 为 vLLM CPU 后端推荐项(性能),缺失不阻塞
sudo apt-get install -y -q libtcmalloc-minimal4 >/dev/null 2>&1 || true

echo "==> [1/6] 构建依赖"
pip install -U pip setuptools wheel ninja "cmake>=3.22" pybind11

echo "==> [2/6] torch(CPU 版,aarch64 官方轮)"
pip install torch --index-url "$PYTORCH_INDEX"

echo "==> [3/6] 源码构建 vLLM(CPU 后端)"
if [ -z "${VLLM_CPU_REF:-}" ]; then
  VLLM_CPU_REF=$(python -c "import json,urllib.request; print(json.load(urllib.request.urlopen('https://pypi.org/pypi/vllm/json', timeout=15))['info']['version'])")
  echo "    VLLM_CPU_REF 未指定,使用 PyPI 最新稳定版: $VLLM_CPU_REF"
fi
if [ ! -d "$WORKROOT/vllm-cpu" ]; then
  git clone --depth 1 --branch "v$VLLM_CPU_REF" https://github.com/vllm-project/vllm.git "$WORKROOT/vllm-cpu"
fi
VLLM_TARGET_DEVICE=cpu pip install -v -e "$WORKROOT/vllm-cpu" --extra-index-url "$PYTORCH_INDEX"
python -c "import vllm; print('vllm(CPU) import OK, version:', vllm.__version__)"

echo "==> [4/6] LMCache(上游)"
if ! pip install lmcache; then
  [ -d "$WORKROOT/LMCache" ] || git clone https://github.com/LMCache/LMCache.git "$WORKROOT/LMCache"
  NO_CUDA_EXT=1 pip install -v --no-build-isolation -e "$WORKROOT/LMCache"
fi
python -c "import lmcache; print('lmcache import OK')" || true

echo "==> [5/6] NIXL"
if ! pip install nixl; then
  echo "    aarch64 轮子不可得,源码构建(POSIX 后端只需 glibc)"
  [ -d "$WORKROOT/nixl" ] || git clone https://github.com/ai-dynamo/nixl.git "$WORKROOT/nixl"
  pip install -e "$WORKROOT/nixl"
fi
python -c "import nixl; print('nixl import OK')"

echo "==> [6/6] 版本清单(复制进报告)"
pip list 2>/dev/null | grep -Ei '^(vllm|lmcache|nixl|torch)' || true
echo "CPU 档安装完成。启动:PROFILE=cpu bash scripts/30_serve.sh"
