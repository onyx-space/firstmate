#!/bin/bash
# 幂等安装器：把 experiments/h-hardening/h/ 下的文件推到 h 机并启用 systemd timer。
# 在 m 机上跑：bash install.sh
#
# 只写它自己管的路径；改动前把被覆盖的文件备份到 /root/h-hardening-backup-<ts>/。
# 不重启 gitea / NAS / syncthing，不重建 outline 容器。
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/h
REMOTE=h
TS=$(date +%Y%m%d-%H%M%S)
BK=/root/h-hardening-backup-$TS

ssh "$REMOTE" "mkdir -p $BK && cp -a /usr/local/bin/container-healthcheck.sh $BK/ 2>/dev/null; cp -a /root/container_healthcheck.sh $BK/root-container_healthcheck.sh 2>/dev/null; cp -a /opt/outline/deploy-outline.sh $BK/ 2>/dev/null || echo 'warn: no /opt/outline/deploy-outline.sh to back up'; crontab -l > $BK/crontab.bak 2>/dev/null || echo 'warn: no crontab to back up'; echo backed-up:$BK"

scp -q "$SRC/container-healthcheck.sh"    "$REMOTE:/usr/local/bin/container-healthcheck.sh"
scp -q "$SRC/deploy-outline.sh"        "$REMOTE:/opt/outline/deploy-outline.sh"
scp -q "$SRC/h-healthcheck-notify.sh"  "$REMOTE:/usr/local/bin/h-healthcheck-notify.sh"
scp -q "$SRC/container-mem-limits.sh"  "$REMOTE:/usr/local/bin/container-mem-limits.sh"
scp -q "$SRC/start-vllm-ascend.sh"     "$REMOTE:/usr/local/bin/start-vllm-ascend.sh"
scp -q "$SRC/container-healthcheck.service"       "$REMOTE:/etc/systemd/system/container-healthcheck.service"
scp -q "$SRC/container-healthcheck.timer"         "$REMOTE:/etc/systemd/system/container-healthcheck.timer"
scp -q "$SRC/container-healthcheck-alert.service" "$REMOTE:/etc/systemd/system/container-healthcheck-alert.service"
scp -q "$SRC/container-mem-limits.service"        "$REMOTE:/etc/systemd/system/container-mem-limits.service"

ssh "$REMOTE" '
set -e
chmod 0755 /usr/local/bin/container-healthcheck.sh /usr/local/bin/h-healthcheck-notify.sh /usr/local/bin/container-mem-limits.sh /usr/local/bin/start-vllm-ascend.sh /opt/outline/deploy-outline.sh
chmod 0644 /etc/systemd/system/container-healthcheck*.service /etc/systemd/system/container-healthcheck.timer /etc/systemd/system/container-mem-limits.service
# SELinux：scp 落盘的文件标签是 admin_home_t，init_t 无权执行 → 单元 203/EXEC。
# 必须 relabel 成 bin_t（restorecon 按 file_contexts 推导，比 chcon 可靠）。
restorecon -v /usr/local/bin/container-healthcheck.sh /usr/local/bin/h-healthcheck-notify.sh /usr/local/bin/container-mem-limits.sh /usr/local/bin/start-vllm-ascend.sh
# 旧路径的副本删掉：两份副本必然漂移
rm -f /root/container_healthcheck.sh
# 摘掉旧 cron 行（幂等；保留 crontab 里的 PATH 行——备份任务还要用）
crontab -l | grep -v "container_healthcheck.sh" | crontab -
systemctl daemon-reload
systemctl enable --now container-healthcheck.timer
systemctl restart container-healthcheck.timer
systemctl enable --now container-mem-limits.service
echo "--- timer ---"
systemctl list-timers container-healthcheck.timer --no-pager
echo "--- crontab ---"
crontab -l
'
echo "installed. backups in $BK"
