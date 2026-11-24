#!/usr/bin/env bash
# A 臂安装:vllm(锁定版, VLLM_TARGET_DEVICE=empty) + vllm-ascend + LMCache + LMCache-Ascend(MP 模式) + NIXL
# 目标环境:GitCode CANN Lab,Atlas A3(910C),CANN 9.0.0 镜像,aarch64。
# 安装耗时较长,建议在 nohup 下执行并观察日志。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

PIP_INDEX_URL="${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
PYTORCH_INDEX="https://download.pytorch.org/whl/cpu/"
ASCEND_PYPI="https://mirrors.huaweicloud.com/ascend/repos/pypi"
export PIP_INDEX_URL
WORKROOT="${WORKROOT:-$HOME/ascend-stack}"
LOGDIR="$SCRIPT_DIR/../run"
mkdir -p "$WORKROOT" "$LOGDIR"
cd "$WORKROOT"

echo "==> [0/6] 检测镜像是否已预装 vllm/vllm-ascend(如官方镜像 VLLM-Ascend-v0.26.0rc-CANN9.1.0-arm)"
if python3 -c "import vllm, vllm_ascend" 2>/dev/null; then
  SKIP_BUILD=1
  echo "    镜像已预装整栈,跳过克隆与源码构建,直接复用厂商对齐版本"
  pip list 2>/dev/null | grep -Ei '^(vllm|torch)' | head -6
else
  SKIP_BUILD=0
  echo "    未预装,走源码安装路径"
fi

if [ "$SKIP_BUILD" = "0" ]; then
echo "==> [1/6] 克隆 vllm-ascend ($VLLM_ASCEND_REF)"
if [ ! -d vllm-ascend ]; then
  # --recurse-submodules:A3 源码安装需要子模块(官方文档要求)
  git clone --depth 1 --branch "$VLLM_ASCEND_REF" --recurse-submodules https://github.com/vllm-project/vllm-ascend.git
fi

# 从 vllm-ascend 的 pyproject.toml 解析它锁定的 vllm 版本(失败则要求手工指定)
VLLM_PIN="${VLLM_REF:-$(grep -oE '"vllm==[0-9][^"]*"' vllm-ascend/pyproject.toml 2>/dev/null | head -n1 | sed 's/"//g; s/^vllm==//')}"
if [ -z "${VLLM_PIN:-}" ]; then
  echo "[错误] 未能从 vllm-ascend/pyproject.toml 解析出锁定的 vllm 版本。" >&2
  echo "       请查阅 vllm-ascend $VLLM_ASCEND_REF tag 的安装文档,在 versions.env 里填 VLLM_REF=<版本> 后重跑。" >&2
  exit 1
fi
echo "    锁定的 vllm 版本: $VLLM_PIN"

echo "==> [2/6] 源码安装 vllm ($VLLM_PIN, VLLM_TARGET_DEVICE=empty,不编译 CUDA 后端)"
if [ ! -d vllm ]; then
  git clone --depth 1 --branch "v$VLLM_PIN" https://github.com/vllm-project/vllm.git vllm
fi
pip install -U pip setuptools wheel ninja "cmake>=3.22" pybind11 setuptools_scm setuptools-rust
VLLM_TARGET_DEVICE=empty pip install -e ./vllm --extra-index-url "$PYTORCH_INDEX"

echo "==> [3/6] 安装 vllm-ascend(torch 与 torch_npu 作为依赖自动安装)"
# 注:若 csrc 自定义算子编译阶段提示需要 SOC_VERSION,按 vllm-ascend 该 tag 文档设置 A3 对应值
pip install -v --no-build-isolation -e ./vllm-ascend \
  --extra-index-url "$PYTORCH_INDEX" --extra-index-url "$ASCEND_PYPI"
fi
# 注:Triton-Ascend / FLA-NPU 是否需要单独安装,以 vllm-ascend 该 tag 文档为准;
# 若文档要求,在此追加:pip install triton-ascend==<文档版本>

echo "==> [4/6] 安装 LMCache ($LMCACHE_REF) 与 LMCache-Ascend ($LMCACHE_ASCEND_REF, MP 模式)"
if [ ! -d LMCache ]; then
  git clone https://github.com/LMCache/LMCache.git LMCache
fi
if [ -n "${LMCACHE_REF:-}" ]; then
  git -C LMCache checkout "$LMCACHE_REF"
fi
if [ ! -d LMCache-Ascend ]; then
  git clone --recurse-submodules https://github.com/LMCache/LMCache-Ascend.git
fi
# NO_CUDA_EXT=1:跳过 CUDA 扩展编译(NPU 环境必需,来自官方部署指南)
NO_CUDA_EXT=1 pip install -v --no-build-isolation -e ./LMCache
pip install -v --no-build-isolation -e ./LMCache-Ascend
# 注:LMCache-Ascend 的 third_party/hcomm 子模块需与容器内 CANN 版本匹配,见官方 README。

echo "==> [5/6] 安装 NIXL"
if [ -n "${NIXL_REF:-}" ]; then
  if [ ! -d nixl ]; then
    git clone https://github.com/ai-dynamo/nixl.git nixl
  fi
  git -C nixl checkout "$NIXL_REF"
  pip install -e ./nixl
else
  pip install nixl
fi
python3 -c "import nixl; print('nixl import OK')" || echo "[warn] nixl import 失败:检查 aarch64 轮子是否带 POSIX 后端,必要时源码构建"

echo "==> [6/6] 版本清单(复制进报告)"
pip list 2>/dev/null | grep -Ei '^(vllm|lmcache|nixl|torch|triton|torch-npu|torchvision)' || true
echo "安装完成。下一步:scripts/20_download_model.sh"
