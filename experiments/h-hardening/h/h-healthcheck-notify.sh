#!/bin/bash
# h-healthcheck-notify.sh <fail|recover>
#
# outline 容器健康检查的告警出口（h 机唯一的主动告警通道）。
#
#   fail     由 container-healthcheck-alert.service 经 systemd OnFailure= 调用
#   recover  由 container-healthcheck.service 的 ExecStartPost 调用（仅当存在未结失败标记时才发）
#
# 三层，逐层兜底：
#   1. journal（daemon.alert / daemon.notice）—— 无外部依赖，`journalctl -t container-healthcheck` 可查
#   2. /var/log/container-healthcheck.failed —— 持久标记文件
#   3. 邮件到队长 163 邮箱（经 h→m 免密 ssh 调 m 机的 163mail CLI）—— 无人值守时唯一能主动找到人的通道
#
# 为什么需要第 3 层：2026-09-14 巡检发现 h 机上 postfix 是 disabled/inactive 且没有 mailx，
# 所有 cron 的 MAILTO=root 告警（本健康检查、backup-snapshots.sh）**全部静默丢弃**。
# 只写标记文件等于没人知道。
#
# 邮件失败不吞掉第 1/2 层：fail 模式对邮件失败返回非 0，systemd 会把本单元标 failed，
# 于是 `systemctl --failed` 会同时列出「检查失败」与「告警通道坏」，不会静默。
# recover 模式的恢复信只是通知：投递失败记 warning 并返回 0，否则 OnFailure 会把一次
# 通过的检查报成故障，还会重新写回刚清掉的失败标记。
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MODE=${1:-fail}
LOG=/var/log/container-healthcheck.log
MARK=/var/log/container-healthcheck.failed
STAMP=/var/run/container-healthcheck.alert.stamp
COOLDOWN=${HEALTHCHECK_ALERT_COOLDOWN:-21600}   # 6h：同一故障期内最多一封邮件
# 自测专用：自测时用 systemd 临时 drop-in 设成 [自测]，让收到邮件的人一眼看出不是真事故。
# 平时未设 = 空。见 report.md 的「故意失败验证」。
TAG=${HEALTHCHECK_ALERT_TAG:-}
MAIL_TO=sunyulai0128@163.com
MAIL_CLI=/Users/onyx/.local/bin/163mail
SSH_OPTS=(-F /root/.ssh/config -o BatchMode=yes -o ConnectTimeout=10)

HOST=$(hostname)
now_h=$(date '+%F %T')
now_e=$(date +%s)

send_mail() {  # <subject> <body>; 成功返回 0
  local subject=$1 body=$2
  { printf '%s\n' "$subject"; printf '%s\n' "$body"; } | \
    ssh "${SSH_OPTS[@]}" m "IFS= read -r s; ${MAIL_CLI} send ${MAIL_TO} \"\$s\"" >/dev/null 2>&1
}

case "$MODE" in
recover)
  [ -f "$MARK" ] || exit 0          # 没有未结失败 → 不发恢复信
  detail=$(cat "$MARK" 2>/dev/null)
  rm -f "$MARK" "$STAMP"
  logger -t container-healthcheck -p daemon.notice "recovered: all checks passing again"
  send_mail "${TAG}[h机恢复] 容器维护检查已恢复正常" \
"$HOST (192.168.1.4) 的容器维护检查已恢复正常，无需处理。

之前的失败记录：
$detail

恢复时间：$now_h
"
  rc=$?
  [ $rc -eq 0 ] || logger -t container-healthcheck -p daemon.warning "recover mail NOT delivered (ssh/163mail rc=$rc)"
  exit 0
  ;;
fail|*)
  printf '%s %s 容器维护检查无法自动恢复\n' "$now_h" "$HOST" >> "$MARK" 2>/dev/null || true
  logger -t container-healthcheck -p daemon.alert "container maintenance check FAILED (health check self-heal exhausted, or memory caps not applied); see $MARK and $LOG"
  detail=$(tail -3 "$MARK" 2>/dev/null)

  last=0
  [ -f "$STAMP" ] && last=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now_e - last)) -lt "$COOLDOWN" ]; then
    logger -t container-healthcheck -p daemon.notice "alert mail suppressed (cooldown ${COOLDOWN}s not elapsed)"
    exit 0
  fi

  send_mail "${TAG}[h机告警] h 机容器维护检查失败" \
"$HOST (192.168.1.4) 的容器维护检查失败。两种可能：outline/gitea 健康检查自愈未成功，
或声明的内存上限没能写进 cgroup。

失败标记（最近 3 行）：
$detail

最近日志：
$(tail -12 "$LOG" 2>/dev/null)

人工排查：
  ssh h
  systemctl --failed
  podman ps -a | grep -E 'outline|gitea'
  podman logs --tail 50 outline-app
  /usr/local/bin/container-mem-limits.sh
  ls -l /var/lib/cni/networks/outline-net/
"
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "$now_e" > "$STAMP"
    logger -t container-healthcheck -p daemon.alert "alert mail sent to $MAIL_TO"
  else
    logger -t container-healthcheck -p daemon.err "alert mail NOT delivered (ssh/163mail rc=$rc)"
  fi
  exit $rc
  ;;
esac
