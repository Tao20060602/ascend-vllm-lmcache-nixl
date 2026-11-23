#!/usr/bin/env bash
# 启动 A 臂服务:lmcache server(MP 模式独立进程) + vllm serve(LMCacheMPConnector)
# 用法:
#   STAGE=l2 bash scripts/30_serve.sh   # 仅 host 内存 L1(LMCache 基线)
#   STAGE=l3 bash scripts/30_serve.sh   # L1 + NIXL POSIX L3
# 可选环境变量: TP=1 PORT=8900 L1_SIZE_GB=8 CHUNK_SIZE=128 STORAGE_DIR=$HOME/lmc_storage
# 终止服务用 scripts/90_teardown.sh(按 PID 终止,禁止 pgrep/pkill 模式匹配)。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

STAGE="${STAGE:-l3}"
PROFILE="${PROFILE:-npu}"   # npu=vllm-ascend+LMCacheMPConnector(独立 lmcache server); cpu=上游 LMCacheConnectorV1(进程内)
TP="${TP:-1}"
PORT="${PORT:-8900}"
# 内存利用率:NPU 档 0.85(显存池);CPU 档 0.30(CPU KV 池预算按整机内存折算,超配会启动失败)
if [ "$PROFILE" = "cpu" ]; then MEM_UTIL="${MEM_UTIL:-0.30}"; else MEM_UTIL="${MEM_UTIL:-0.85}"; fi
L1_SIZE_GB="${L1_SIZE_GB:-8}"
CHUNK_SIZE="${CHUNK_SIZE:-128}"
MODEL_ROOT="${MODEL_ROOT:-$HOME/models}"
MODEL_DIR="$MODEL_ROOT/$MODEL_DIR_NAME"
STORAGE_DIR="${STORAGE_DIR:-$HOME/lmc_storage}"
RUNDIR="$SCRIPT_DIR/../run"
mkdir -p "$RUNDIR"

if [ ! -d "$MODEL_DIR" ]; then
  echo "[错误] 模型目录不存在: $MODEL_DIR,先执行 scripts/20_download_model.sh" >&2
  exit 1
fi

# CPU 档环境:激活 venv(11_install_cpu_stack.sh 创建);NPU 档环境不受影响
if [ -f "$HOME/venv-vllm-cpu/bin/activate" ]; then
  # shellcheck disable=SC1091
  source "$HOME/venv-vllm-cpu/bin/activate"
fi

# 1) 渲染 LMCache 配置(l3 模板中的 @STORAGE_DIR@ 替换为实际路径)
mkdir -p "$STORAGE_DIR"
if [ "$STAGE" = "l3" ]; then
  sed "s|@STORAGE_DIR@|$STORAGE_DIR|g" "$SCRIPT_DIR/../configs/lmcache_l3_nixl.yaml.template" > "$RUNDIR/lmcache.yaml"
else
  cp "$SCRIPT_DIR/../configs/lmcache_l2.yaml" "$RUNDIR/lmcache.yaml"
fi
export LMCACHE_CONFIG_FILE="$RUNDIR/lmcache.yaml"
echo "LMCache 配置: $LMCACHE_CONFIG_FILE"

# 连接器统一走 MP 模式:vLLM 0.34 内置 LMCacheConnectorV1 默认分支导入的
# lmcache.integration.vllm.vllm_v1_adapter 在 lmcache 0.5.8 已被删除(0.5.6 尚存),
# 且 vllm requirements/kv_connectors.txt 声明的范围是 lmcache>=0.5.6,按其声明装最新必炸
# (已确认 LMCacheMPConnector 为官方替代,依赖 vllm_multi_process_adapter,0.5.8 中存在)
KV_CONNECTOR="LMCacheMPConnector"
echo "连接器: $KV_CONNECTOR(MP 模式,需独立 lmcache server 进程)"

if [ "$PROFILE" = "cpu" ]; then
  # 容器 /dev/shm 常为 64 MiB,vLLM 引擎核共享内存环缓冲需 160 MiB 以上,不足则重挂载
  SHM_FREE=$(df -k /dev/shm 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "${SHM_FREE:-}" ] && [ "$SHM_FREE" -lt 262144 ]; then
    echo "/dev/shm 可用 ${SHM_FREE} KiB 不足,重挂载为 8 GiB(sudo)"
    sudo mount -o remount,size=8G /dev/shm || echo "[warn] /dev/shm 重挂载失败,vLLM 可能启动失败"
  fi
fi

# kv-transfer-config:CPU 平台没有 CUDA VMM,显式关闭 lmcache.mp.use_vmm_api
# (LEGACY_IPC 模式),否则 vllm 校验直接拒绝(extensible KV cache 仅 CUDA/ROCm)
if [ "$PROFILE" = "cpu" ]; then
  KV_TF_CONFIG="{\"kv_connector\": \"$KV_CONNECTOR\", \"kv_role\": \"kv_both\", \"kv_connector_extra_config\": {\"lmcache.mp.use_vmm_api\": false}}"
  # use_vmm_api=false 走 LEGACY_IPC,worker 以 engine_driven 模式注册,server 需显式启用
  SRV_MODE_ARGS="--supported-transfer-mode engine_driven"
else
  KV_TF_CONFIG="{\"kv_connector\": \"$KV_CONNECTOR\", \"kv_role\": \"kv_both\"}"
  SRV_MODE_ARGS=""
fi

# 2) 启动 lmcache server(MP 模式必需的独立进程;CPU/NPU 共用上游 CLI)
nohup lmcache server \
  --chunk-size "$CHUNK_SIZE" \
  --l1-size-gb "$L1_SIZE_GB" \
  --eviction-policy LRU \
  $SRV_MODE_ARGS \
  > "$RUNDIR/lmcache_server.log" 2>&1 < /dev/null &
echo $! > "$RUNDIR/lmcache_server.pid"
sleep 5
LMC_PID=$(cat "$RUNDIR/lmcache_server.pid")
if ! kill -0 "$LMC_PID" 2>/dev/null; then
  echo "    带参启动失败,降级为无参(仅依赖 LMCACHE_CONFIG_FILE)"
  nohup lmcache server > "$RUNDIR/lmcache_server.log" 2>&1 < /dev/null &
  echo $! > "$RUNDIR/lmcache_server.pid"
  sleep 5
  LMC_PID=$(cat "$RUNDIR/lmcache_server.pid")
fi
if ! kill -0 "$LMC_PID" 2>/dev/null; then
  echo "[错误] lmcache server 启动失败,日志末尾:" >&2
  tail -n 30 "$RUNDIR/lmcache_server.log" >&2
  exit 1
fi
echo "lmcache server 已启动, PID=$LMC_PID, 日志=$RUNDIR/lmcache_server.log"

# 3) 启动 vllm serve
#    --no-enable-prefix-caching:vllm 引擎内前缀缓存交给 LMCache 管理(官方示例同款)
#    --enforce-eager:NPU 上先跑通 eager 模式,图模式(torch.air)作为后续性能项
#    TP>1 时用满 2 卡:TP=2 bash scripts/30_serve.sh
nohup vllm serve "$MODEL_DIR" \
  --served-model-name test \
  --max-model-len 8192 \
  --max-num-batched-tokens 4096 \
  --tensor-parallel-size "$TP" \
  --gpu-memory-utilization "$MEM_UTIL" \
  --no-enable-prefix-caching \
  --enforce-eager \
  --port "$PORT" \
  --kv-transfer-config "$KV_TF_CONFIG" \
  > "$RUNDIR/vllm.log" 2>&1 < /dev/null &
echo $! > "$RUNDIR/vllm.pid"
sleep 8
VLLM_PID=$(cat "$RUNDIR/vllm.pid")
if ! kill -0 "$VLLM_PID" 2>/dev/null; then
  echo "[错误] vllm 进程立即退出,日志末尾:" >&2
  tail -n 40 "$RUNDIR/vllm.log" >&2
  exit 1
fi
echo "vllm 已启动(PID=$VLLM_PID),模型加载约需数分钟。"
echo "就绪检测: bash scripts/40_smoke.sh"
echo "  日志: $RUNDIR/vllm.log"
