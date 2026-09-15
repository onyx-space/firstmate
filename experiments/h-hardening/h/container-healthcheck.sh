#!/bin/bash
# h机 关键容器健康检查：检测端口转发卡死 / 容器未运行，并尝试自愈
#
# 调度（2026-09-14 起）：systemd timer `container-healthcheck.timer`（每小时），
#   systemctl list-timers container-healthcheck.timer
#   systemctl status container-healthcheck.service
#   journalctl -u container-healthcheck.service -n 50
#   失败 → OnFailure= 拉起 container-healthcheck-alert.service（journal + 标记 + 邮件）
# （旧形态是 root crontab 的 `0 * * * *`；已摘除——cron 不给显式 PATH、失败只在 journal 里躺着。）
#
# 与原版的差别：
#   -1. （2026-09-14）脚本自含 PATH，见下方 export；
#   1. podman restart 失败时兜底 podman start 一次；
#   2. 两者都失败 → 写醒目标记 + 非 0 退出（systemd 据此触发告警单元）；
#   3. 失败原因写进日志与标记文件，不再静默躺平。
#
# ⚠️ 依赖 PATH 里能找到 iptables（/usr/sbin）。下面是自含的兜底；
#    systemd 单元里也显式设了同一条 PATH（双保险）。**删掉任何一处都可能复现
#    2026-09-10 的停服**：podman 的网络写操作（CNI DEL）会半途失败 → IPAM 租约泄漏
#    → 下次 start 报 IP 地址冲突、容器永远起不来（那次 outline 停了约 2 小时）。
#
# 每 1 小时由 systemd timer 调用；数据都在持久卷，重启无损。
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

FAILMARK=/var/log/container-healthcheck.failed

note() { echo "$(date '+%F %T') $*"; }

check_port() {  # <port> <container>
  local port=$1 container=$2 code
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 \
    "http://127.0.0.1:${port}/" 2>/dev/null || true)
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    note "[ok] ${container} (port ${port}) code=${code}"
    return 0
  fi

  note "[RESTART] ${container} (port ${port}) 无响应 code=${code:-none} -> podman restart"
  if podman restart "${container}" >/dev/null 2>&1; then
    note "[ok] ${container} restart 成功"
    return 0
  fi

  note "[WARN] ${container} restart 失败 -> 兜底 podman start"
  if podman start "${container}" >/dev/null 2>&1; then
    note "[ok] ${container} start 成功（兜底）"
    return 0
  fi

  note "[FAIL] ${container} 无法自动恢复：restart 与 start 均失败（port ${port} code=${code:-none}）"
  note "[FAIL] 人工检查：podman ps -a | grep ${container}；ls -l /var/lib/cni/networks/outline-net/；podman logs --tail 50 ${container}"
  printf '%s %s 无法自动恢复（port %s）\n' "$(date '+%F %T')" "${container}" "${port}" >> "$FAILMARK" 2>/dev/null || true
  return 1
}

rc=0
check_port 60920 outline-app || rc=1
check_port 60921 outline-dex || rc=1
check_port 3000 gitea || rc=1

# 上限重写放在这里而不是单元的 ExecStartPost：ExecStart 非 0 时 ExecStartPost 一律不执行，
# 而「有容器刚被 restart 过」正是 cgroup 上限被重建丢掉、最需要补的时刻。
/usr/local/bin/container-mem-limits.sh || rc=1
exit "$rc"
