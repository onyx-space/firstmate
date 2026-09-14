#!/bin/bash
# 内存上限语义自证 —— 在 h 机上运行：ssh h 'bash -s' < verify-memory-limit.sh
#
# 用一次性牺牲容器证明（不碰任何生产容器）：
#   A. --memory 真的落进 cgroup（memory.limit_in_bytes == 设定值）
#   B. container-mem-limits.sh 把 podman 不写的 memsw 补上（h 机 cgroup v1 的坑，
#      见 container-mem-limits.sh 头注释）—— 没有这一步容器可以靠 swap 顶，宿主被拖死
#   C. 超限时是**容器被 cgroup OOM kill**（内核 `constraint=CONSTRAINT_MEMCG`），**宿主存活**
#   D. --restart=always 把被杀的容器重新拉起（RestartCount 增长）
#
# 证据以**内核日志**为准，不信 podman 的 .State.OOMKilled：
# 实测（2026-09-14）podman 4.9.4 + cgroup v1 上该字段恒为 false，即使内核明确是 MEMCG OOM。
# 内核那行才带着 attribution：
#   oom-kill:constraint=CONSTRAINT_MEMCG,oom_memcg=/machine.slice/libpod-<id>.scope/container,...
#   Memory cgroup out of memory: Killed process <pid> (python3) ... anon-rss:65536kB
#
# 负载：ai-base 镜像的 python3 分配并写入 600MB 匿名内存（`b'x' * 600MB`），
#   64MB 上限下必然被杀。先 sleep 6 留出补 memsw 的窗口。
# 踩过的坑：alpine/busybox 的 awk / shell 字符串翻倍会提前**正常退出**，
#   RestartCount 照样在涨、看着像"被杀了"，但 memory.failcnt 一直是 0 —— 根本没触发 OOM。
#
# 退出码 0 = 全部通过；1 = 有断言失败。
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

NAME=memlimit-selftest
LIMIT=64m
LIMIT_BYTES=67108864
IMG=localhost/ai-base:latest
LOAD="import time; time.sleep(6); b = b'x' * (600*1024*1024); print(len(b))"
fail=0
ck() { if [ "$2" = "$3" ]; then echo "  PASS  $1: $2"; else echo "  FAIL  $1: got '$2' want '$3'"; fail=1; fi; }
memcg_oom_count() { journalctl -k --no-pager 2>/dev/null | grep -c "constraint=CONSTRAINT_MEMCG"; }

echo "=== 内存上限语义自证 @ $(hostname) $(date '+%F %T') ==="
podman rm -f "$NAME" >/dev/null 2>&1 || true

echo "--- 0. 宿主基线 ---"
uptime
free -m | head -2

echo
echo "--- A/B. 声明上限 → cgroup 落值（含 memsw）---"
podman run -d --name "$NAME" --memory=$LIMIT --memory-swap=$LIMIT --restart=no \
  --entrypoint python3 "$IMG" -c "$LOAD" >/dev/null
echo "  podman run rc=$?"
sleep 1
CGP="/sys/fs/cgroup/memory$(podman inspect "$NAME" --format '{{.State.CgroupPath}}')"
echo "  podman run 之后：memory=$(cat "$CGP/memory.limit_in_bytes" 2>/dev/null) memsw=$(cat "$CGP/memory.memsw.limit_in_bytes" 2>/dev/null)"
/usr/local/bin/container-mem-limits.sh "$NAME" "$LIMIT" 2>&1 | grep -E "^\[(ok|FAIL)\]" || true
ck "A. cgroup memory.limit_in_bytes"       "$(cat "$CGP/memory.limit_in_bytes" 2>/dev/null)"       "$LIMIT_BYTES"
ck "B. cgroup memory.memsw.limit_in_bytes" "$(cat "$CGP/memory.memsw.limit_in_bytes" 2>/dev/null)" "$LIMIT_BYTES"

echo
echo "--- C. 超限 → cgroup OOM kill（内核证据）---"
before=$(memcg_oom_count)
for i in $(seq 1 40); do
  [ "$(memcg_oom_count)" -gt "$before" ] && break
  sleep 1
done
after=$(memcg_oom_count)
echo "  内核 CONSTRAINT_MEMCG OOM kill 次数：+$((after - before))（等待 $((i)) s）"
journalctl -k --no-pager 2>/dev/null | grep "constraint=CONSTRAINT_MEMCG" | tail -1 | sed 's/^/  /'
journalctl -k --no-pager 2>/dev/null | grep "Memory cgroup out of memory" | tail -1 | sed 's/^/  /'
cid=$(podman inspect "$NAME" --format '{{.Id}}')
if [ $((after - before)) -ge 1 ] && journalctl -k --no-pager 2>/dev/null | grep "CONSTRAINT_MEMCG" | tail -1 | grep -q "${cid:0:12}"; then
  echo "  PASS  超限被本容器 cgroup（${cid:0:12}…）的 MEMCG OOM 杀死"
else
  echo "  FAIL  未看到归属于本容器的 MEMCG OOM kill"; fail=1
fi
echo "  podman 报告：$(podman inspect "$NAME" --format 'status={{.State.Status}} exit={{.State.ExitCode}} oomkilled={{.State.OOMKilled}}')"
ck "C. ExitCode（SIGKILL=137）" "$(podman inspect "$NAME" --format '{{.State.ExitCode}}')" "137"

echo
echo "--- C-still-alive. 宿主存活 + 生产容器未受影响 ---"
[ -n "$(uptime -p)" ] && echo "  PASS  宿主仍可响应: $(uptime -p)"
for c in outline-app outline-db outline-redis outline-dex gitea; do
  printf '  %-14s %s\n' "$c" "$(podman inspect "$c" --format '{{.State.Status}}' 2>&1)"
done
free -m | head -2

echo
echo "--- D. --restart=always 把被杀的容器拉回来 ---"
podman rm -f "$NAME" >/dev/null 2>&1 || true
podman run -d --name "$NAME" --memory=$LIMIT --memory-swap=$LIMIT --restart=always \
  --entrypoint python3 "$IMG" -c "$LOAD" >/dev/null
sleep 1
/usr/local/bin/container-mem-limits.sh "$NAME" "$LIMIT" >/dev/null 2>&1
sleep 18
RC=$(podman inspect "$NAME" --format '{{.RestartCount}}')
echo "  $(podman inspect "$NAME" --format 'status={{.State.Status}} restarts={{.RestartCount}}')"
if [ "${RC:-0}" -ge 2 ]; then echo "  PASS  RestartCount=$RC >= 2（被杀后反复拉起）"; else echo "  FAIL  RestartCount=$RC（期望 >=2）"; fail=1; fi

echo
echo "--- E. 清理牺牲容器 ---"
podman rm -f "$NAME" >/dev/null 2>&1
podman ps -a --format '{{.Names}}' | grep -qx "$NAME" && { echo "  FAIL  清理失败"; fail=1; } || echo "  PASS  已删除"

echo
echo "=== 结果: $([ $fail -eq 0 ] && echo ALL PASS || echo FAILED) ==="
exit $fail
