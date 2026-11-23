#!/usr/bin/env bash
# A 臂 CPU 档安装:vLLM(CPU 后端,aarch64 源码构建) + LMCache(上游,进程内连接器) + NIXL
# 与 NPU 档(10_install_stack.sh)的区别:
#   1) 不装 vllm-ascend / torch_npu / LMCache-Ascend(CPU 仿真环境无 NPU,这些组件不可用也无必要);
#   2) KV 连接器用上游 LMCacheConnectorV1(进程内),不用 LMCacheMPConnector(独立服务进程);
#   3) 本档的目标是预集成验证:配置接受度、L3 落盘、命中记账,而非性能结论。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

PIP_INDEX_URL="${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
PYTORCH_INDEX="https://download.pytorch.org/whl/cpu/"
export PIP_INDEX_URL
WORKROOT="${WORKROOT:-$HOME/ascend-stack}"
LOGDIR="$SCRIPT_DIR/../run"
mkdir -p "$WORKROOT" "$LOGDIR"
cd "$WORKROOT"
# aarch64 源码编译 C++ 较重,限制并行度防内存耗尽(30 GiB 内存环境取 8)
export MAX_JOBS="${MAX_JOBS:-8}"

echo "==> [1/6] 构建依赖(ninja/cmake,00 体检显示缺失)"
pip install -U pip setuptools wheel ninja "cmake>=3.22" pybind11

echo "==> [2/6] 安装 torch(CPU 版,aarch64 官方轮)"
pip install torch --index-url "$PYTORCH_INDEX"

echo "==> [3/6] 源码构建 vLLM(CPU 后端)"
if [ -z "${VLLM_CPU_REF:-}" ]; then
  VLLM_CPU_REF=$(python3 -c "import json,urllib.request; print(json.load(urllib.request.urlopen('https://pypi.org/pypi/vllm/json', timeout=15))['info']['version'])")
  echo "    VLLM_CPU_REF 未指定,使用 PyPI 最新稳定版: $VLLM_CPU_REF"
fi
if [ ! -d vllm-cpu ]; then
  git clone --depth 1 --branch "v$VLLM_CPU_REF" https://github.com/vllm-project/vllm.git vllm-cpu
fi
VLLM_TARGET_DEVICE=cpu pip install -v -e ./vllm-cpu --extra-index-url "$PYTORCH_INDEX"
python3 -c "import vllm; print('vllm(CPU) import OK, version:', vllm.__version__)"

echo "==> [4/6] 安装 LMCache(上游)"
if pip install lmcache; then
  python3 -c "import lmcache; print('lmcache(PyPI) import OK')" || true
else
  echo "    PyPI 安装失败,改源码安装(上游 main)"
  [ -d LMCache ] || git clone https://github.com/LMCache/LMCache.git LMCache
  NO_CUDA_EXT=1 pip install -v --no-build-isolation -e ./LMCache
fi

echo "==> [5/6] 安装 NIXL"
if pip install nixl; then
  python3 -c "import nixl; print('nixl(PyPI wheel) import OK')" || true
else
  echo "    aarch64 轮子不可得,源码构建(POSIX 后端只需 glibc)"
  [ -d nixl ] || git clone https://github.com/ai-dynamo/nixl.git nixl
  pip install -e ./nixl
fi
python3 -c "import nixl; print('nixl import OK')"

echo "==> [6/6] 版本清单(复制进报告)"
pip list 2>/dev/null | grep -Ei '^(vllm|lmcache|nixl|torch)' || true
echo "CPU 档安装完成。下一步:PROFILE=cpu bash scripts/30_serve.sh"
