#!/bin/bash
# 容器内存上限 —— 唯一声明源 + 执行点（h 机 cgroup v1 的两个 podman 坑的补丁）。
#
# 为什么不是写 `podman run --memory` 就完了（2026-09-14 实测 podman 4.9.4 + cgroup v1）：
#   坑 1：`--memory-swap` 不生效。HostConfig.MemorySwap 记录了值，但
#         memory.memsw.limit_in_bytes 仍是 unlimited，`podman update --memory-swap` 同样不写。
#         手动 echo 进去内核接受 → 是 podman 不写，不是内核不支持。
#         后果：只设 --memory 时容器超限还能拿 swap 顶 → 宿主被拖进 swap 抖动，正是要防的"拖死宿主"。
#   坑 2：`podman update --memory` 只改 cgroup，**不回写容器 config**（inspect 里 HostConfig.Memory 仍为 0）。
#         所以容器一重启，cgroup 按旧 config 重建 → 上限静默消失。
#
# 因此上限表放在这里（唯一声明源），由本脚本写进 cgroup，并且**每小时重写一次**
# （container-healthcheck.timer 同时激活本脚本的 service），把重启后丢掉的上限补回来。
# 开机也跑（container-mem-limits.service，After=podman-restart.service）。
#
# 用法：container-mem-limits.sh                   全表执行
#       container-mem-limits.sh <容器名>            只执行表中那个容器
#       container-mem-limits.sh <容器名> <上限>     一次性按给定上限执行（自证脚本用，绕过表）
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# <容器名> <上限>   —— 上限同时作为 memsw（= 该容器禁用 swap，超限直接 OOM kill）
# 取值依据（2026-09-14 实测用量 → 5~13 倍余量；正常运行碰不到，只挡无界增长）：
#   outline-app  412MB rss  → 2g
#   outline-db   1.7MB rss  → 2g（postgres 大查询/sort 要留余量）
#   outline-redis 7.6MB     → 512m
#   outline-dex  16MB       → 256m
#   vllm-ascend  59.8GB rss（4× Qwen3-VL-8B 权重常驻宿主内存）→ 88g，宽松到不影响正常推理，
#                但挡住无界增长拖死宿主（h 机是家里唯一常开服务器，还跑着 gitea / NAS / syncthing）
MEM_LIMITS="
outline-app   2g
outline-db    2g
outline-redis 512m
outline-dex   256m
vllm-ascend   88g
"

to_bytes() {  # 2g / 512m / 256m / 1024k → 字节
  local v=$1 n unit
  n=${v%[kKmMgG]}
  unit=${v: -1}
  case "$unit" in
    g|G) echo $((n * 1024 * 1024 * 1024)) ;;
    m|M) echo $((n * 1024 * 1024)) ;;
    k|K) echo $((n * 1024)) ;;
    *)   echo "$n" ;;
  esac
}

ONLY=${1:-}
ONLY_LIMIT=${2:-}
if [ -n "$ONLY_LIMIT" ]; then WORK="$ONLY $ONLY_LIMIT"; else WORK="$MEM_LIMITS"; fi
rc=0
while read -r name limit; do
  [ -n "${name:-}" ] || continue
  [ -n "$ONLY" ] && [ -z "$ONLY_LIMIT" ] && [ "$name" != "$ONLY" ] && continue

  if ! podman container exists "$name" 2>/dev/null; then
    echo "[skip] $name: 容器不存在"; continue
  fi
  if [ "$(podman inspect "$name" --format '{{.State.Status}}' 2>/dev/null)" != "running" ]; then
    echo "[skip] $name: 未运行（上限会在下次运行或每小时重跑时补上）"; continue
  fi

  bytes=$(to_bytes "$limit")
  cg="/sys/fs/cgroup/memory$(podman inspect "$name" --format '{{.State.CgroupPath}}' 2>/dev/null)"
  if [ ! -d "$cg" ]; then echo "[FAIL] $name: cgroup 未找到（$cg）"; rc=1; continue; fi

  if ! echo "$bytes" > "$cg/memory.limit_in_bytes" 2>/dev/null; then
    echo "[FAIL] $name: 写 memory.limit_in_bytes=$bytes ($limit) 失败（当前用量可能已超该值）"; rc=1; continue
  fi
  if ! echo "$bytes" > "$cg/memory.memsw.limit_in_bytes" 2>/dev/null; then
    echo "[FAIL] $name: 写 memory.memsw.limit_in_bytes=$bytes 失败"; rc=1; continue
  fi
  echo "[ok] $name: memory=$limit memsw=$limit（cgroup: $(cat "$cg/memory.limit_in_bytes") / $(cat "$cg/memory.memsw.limit_in_bytes")）"
done <<< "$WORK"
exit "$rc"
