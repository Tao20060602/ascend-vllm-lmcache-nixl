#!/usr/bin/env bash
# 按 PID 终止服务(约束:禁止 pgrep/pkill 模式匹配,模式会误杀无关进程)
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNDIR="$SCRIPT_DIR/../run"

for pidfile in "$RUNDIR"/*.pid; do
  [ -f "$pidfile" ] || continue
  name=$(basename "$pidfile" .pid)
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    echo "终止 $name (PID=$pid)..."
    kill "$pid" 2>/dev/null || true
    # 最多等 30 秒优雅退出,超时按 PID 强杀
    for i in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "  超时未退出,kill -9 $pid"
      kill -9 "$pid" 2>/dev/null || true
    fi
  else
    echo "$name: 进程已不存在"
  fi
  rm -f "$pidfile"
done
echo "teardown 完成。确认端口已释放: ss -ltnp | grep -E '8900|5555' || true"
