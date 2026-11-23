#!/usr/bin/env bash
# 从 ModelScope 下载冒烟模型(GitCode 容器内对 HuggingFace 直连不稳定,ModelScope 走国内网络)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../versions.env
source "$SCRIPT_DIR/../versions.env"

MODEL_ROOT="${MODEL_ROOT:-$HOME/models}"
MODEL_DIR="$MODEL_ROOT/$MODEL_DIR_NAME"

if [ -d "$MODEL_DIR" ] && [ -n "$(ls -A "$MODEL_DIR" 2>/dev/null)" ]; then
  echo "模型已存在: $MODEL_DIR,跳过下载。"
  exit 0
fi

pip install -U modelscope
mkdir -p "$MODEL_DIR"
modelscope download --model "$MODEL_ID" --local_dir "$MODEL_DIR"
echo "下载完成: $MODEL_DIR"
du -sh "$MODEL_DIR"
