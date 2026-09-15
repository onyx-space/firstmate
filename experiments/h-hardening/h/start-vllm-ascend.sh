#!/bin/bash
# vllm-ascend 容器创建/启动（幂等）—— 补上原先不存在的「重建路径」。
#
# 背景（2026-09-14）：这个容器此前没有任何创建脚本，全套脚本里只有 `podman start vllm-ascend`
# （`start-qwen3vl-instance.sh` 里的），而且没设 restart 策略 —— 容器一死不会自己回来，
# 4 个 Qwen3-VL-8B 实例（60911-60914）一起消失。队长 2026-09-14 授权补 `--restart=always`
# 并知悉重建窗口内 8B 端点停机数分钟。
#
# 参数逐条取自改前的 `podman inspect vllm-ascend --format '{{json .Config.CreateCommand}}'`，
# 唯一增补是 `--restart=always`。
#
# ⚠️ 原配方里的 `--env-file /tmp/vllm-ascend.env` **不再传**，理由是实测的：
#    - 该文件在 tmpfs 上，重建时已不存在（`ls /tmp/vllm-ascend.env` → No such file）；
#    - 逐条比对容器 env 与镜像 env（`podman image inspect ... .Config.Env`）后，
#      `--env-file` 当时只贡献了 podman 自己注入的 HOME / HOSTNAME / container 三个变量，
#      其余全部来自镜像自带的 27 个 ENV —— 不传是行为等价的。
#    （这也说明原配方依赖一个 tmpfs 上的文件，重启即不可重建，本身就是隐患。）
#
# 内存上限：权威声明源是 `container-mem-limits.sh` 的 `MEM_LIMITS` 表（该容器 88g）。
# 这里也显式传同值，好处是 `podman inspect` 自描述、且 podman 自己重启时能应用 memory；
# **memsw 仍然必须靠那张表补**（h 机 cgroup v1 上 podman 不写 memory.memsw.limit_in_bytes）。
# 所以：改上限时两处都要改（表和这里）；memsw 与每小时重写仍只归那张表。
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

NAME=vllm-ascend
IMG=quay.io/ascend/vllm-ascend:v0.23.0rc1-310p
MEM=88g

if podman container exists "$NAME"; then
  st=$(podman inspect "$NAME" --format '{{.State.Status}}')
  if [ "$st" = "running" ]; then
    echo "[ok] $NAME 已在运行"
  else
    echo "[start] $NAME 存在但未运行（$st）→ podman start"
    podman start "$NAME"
  fi
else
  echo "[create] $NAME 不存在 → 按 2026-09-14 固化的配方创建（含 --restart=always）"
  podman run -d --name "$NAME" \
    --device /dev/davinci0 --device /dev/davinci1 --device /dev/davinci2 --device /dev/davinci3 \
    --device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc \
    -v /home/host/models:/models:Z \
    -v /home/host/vllm-cache:/root/.cache:Z \
    -v /usr/local/dcmi:/usr/local/dcmi \
    -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
    -v /usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64/ \
    -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
    -v /etc/ascend_install.info:/etc/ascend_install.info \
    --shm-size=8g --net=host \
    --restart=always \
    --memory="$MEM" --memory-swap="$MEM" \
    "$IMG" sleep infinity
  echo "[ok] $NAME 已创建"
fi

sleep 2
# 补 memsw（podman 不写），并确认上限落地
/usr/local/bin/container-mem-limits.sh "$NAME" "$MEM" || true
echo "--- 当前状态 ---"
podman inspect "$NAME" --format 'status={{.State.Status}} restart={{.HostConfig.RestartPolicy.Name}} image={{.ImageName}} net={{.HostConfig.NetworkMode}}'
