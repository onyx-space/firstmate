#!/bin/bash
# ⚠️ 危险脚本：本脚本会 rm -f 并重建全部 4 个容器（db / redis / dex / app），
#    不是"只重建 app"。只重建 app 请走部署文档 §6 的单容器流程。
# ⚠️ 运行前确认：镜像 tag 必须与线上一致（2026-09-10 修正为 1.9.2-patched-rl，
#    旧 tag 不含 429 限流修复）。CNI 残留租约会让 start 报 IP 冲突，
#    必要时先清理 /var/lib/cni/networks/outline-net/<IP>。
# ⚠️ root crontab 的 PATH 必须含 /usr/sbin（否则 podman 网络写操作会半途失败）。
#    健康检查已迁到 systemd timer（自带显式 PATH），cron 那条只剩备份任务。
# ⚠️ PATH 也要含 /usr/sbin：本脚本自身依赖 podman 的网络写操作。
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
NET=outline-net
# 固定 IP 规划
DB_IP=10.90.0.10
REDIS_IP=10.90.0.11
DEX_IP=10.90.0.12
APP_IP=10.90.0.13

# 内存上限（2026-09-14 加）：原来四个容器都没有上限，任一泄漏都能把宿主拖死
# （h 机是家里唯一常开服务器，上面还跑着 gitea / NAS / syncthing）。
# ⚠️ 上限的**声明源不在本文件**，而在 /usr/local/bin/container-mem-limits.sh 的 MEM_LIMITS 表。
#    原因：h 机 cgroup v1 + podman 4.9.4 下 `--memory-swap` 根本不写 memsw，
#    且 `podman update --memory` 不回写容器 config（重启就丢）—— 只有直接写 cgroup 可靠。
#    所以这里不传 --memory/--memory-swap（传了反而造成第二份真相），
#    由脚本结尾调用的 container-mem-limits.sh 统一落地。

echo "==> postgres"
sudo podman rm -f outline-db >/dev/null 2>&1 || true
sudo podman run -d --name outline-db --network $NET --ip $DB_IP \
  -e POSTGRES_USER=outline -e POSTGRES_PASSWORD=outline_password -e POSTGRES_DB=outline \
  -v /nas/data/outline/pgdata:/var/lib/postgresql/data:Z \
  --restart=always \
  docker.io/postgres:16-alpine

echo "==> redis"
sudo podman rm -f outline-redis >/dev/null 2>&1 || true
sudo podman run -d --name outline-redis --network $NET --ip $REDIS_IP \
  -v outline-redisdata:/data \
  --restart=always \
  docker.io/redis:7-alpine

echo "==> dex"
sudo podman rm -f outline-dex >/dev/null 2>&1 || true
sudo podman run -d --name outline-dex --network $NET --ip $DEX_IP \
  -p 60921:5556 \
  -v /opt/outline/dex:/var/dex:Z \
  --restart=always \
  ghcr.io/dexidp/dex:v2.41.1 dex serve /var/dex/config.yaml

echo "==> outline-app"
sudo podman rm -f outline-app >/dev/null 2>&1 || true
sudo podman run -d --name outline-app --network $NET --ip $APP_IP \
  -p 60920:3000 \
  --user 1000:1000 \
  -v /nas/data/outline/data:/var/lib/outline/data:Z \
  --restart=always \
  --env-file /opt/outline/outline.env \
  localhost/outline:1.9.2-patched-rl

echo "ALL CONTAINERS STARTED"
sudo podman ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.IPAddress}}" | grep -E "NAMES|outline"

# ⚠️ 必须跑这一步：内存上限的唯一落地入口（见文件头注释）。
#    不要在这里改 --memory：上限表在脚本里，两处写就是两份真相。
/usr/local/bin/container-mem-limits.sh
