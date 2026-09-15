# h 机 outline 防复发加固（experimental）

> **STATUS: experimental** — 可能被重写或删除。这些文件是 2026-09-14 巡检对 h 机（192.168.1.4）
> 三项加固改动的**部署源**：h 机上的同名文件由 `install.sh` 从本目录幂等推送，
> 改完本目录要重跑 `install.sh` 才会落到 h 机（实机形态可能落后于本目录）。
> 部署事实、逐条验证证据与回滚步骤见 `/Users/onyx/code/firstmate/data/h-hardening/report.md`；
> 运维文档见 vault `/Users/onyx/memory/outline-h-server-deploy.md`（§5）。

三项：

1. **健康检查从裸 cron 迁到 systemd timer** — 显式 PATH、失败可 `systemctl --failed`/`journalctl` 查，
   失败经 `OnFailure=` 触发告警（journal + 标记文件 + **邮件到队长 163 邮箱**，6h 冷却，恢复时另发一封）。
   起因：2026-09-10 停服约 2 小时，根因是调用方 PATH 缺 `/usr/sbin` 导致 podman CNI 网络写操作半途失败；
   而原有的 `MAILTO=root` 告警**本来也发不出去**（h 机 postfix disabled、无 mailx）。
2. **容器内存上限** — outline 四容器 + `vllm-ascend` 的 cgroup 上限与 memsw。
   权威声明源是 `container-mem-limits.sh` 的 `MEM_LIMITS` 表（为什么不把 `podman run --memory`
   当声明源：h 机 cgroup v1 上 `--memory-swap` 空转，且 `podman update` 不回写 config、重启即丢）。
   每小时 + 开机 + 每次 `deploy-outline.sh` 重写一次。
   未做→**已做**（2026-09-14 22:55，队长授权）：`vllm-ascend` 现已 `--restart=always`，
   并补上了原先不存在的容器创建脚本 `start-vllm-ascend.sh`。
3. **文档对齐** — 脚本/实机为准，vault 部署文档跟上（11 处差异清单见报告 §4）。

## 目录

| 路径 | 部署到 h 机 | 作用 |
|---|---|---|
| `h/container-healthcheck.service` | `/etc/systemd/system/` | 检查 oneshot：显式 PATH + `OnFailure=` + 脚本末尾重写上限 + `ExecStartPost` 发恢复通知 |
| `h/container-healthcheck.timer` | `/etc/systemd/system/` | 每小时；`Persistent=true` |
| `h/container-healthcheck-alert.service` | `/etc/systemd/system/` | 检查失败时由 systemd 拉起 |
| `h/h-healthcheck-notify.sh` | `/usr/local/bin/` | 告警出口：journal + 标记 + 邮件（冷却 / 恢复 / 自测前缀） |
| `h/container-healthcheck.sh` | `/usr/local/bin/` | 检查逻辑本体（自含 PATH） |
| `h/container-mem-limits.sh` | `/usr/local/bin/` | **内存上限权威声明源** + 落地（memory + memsw） |
| `h/container-mem-limits.service` | `/etc/systemd/system/` | 开机后（`After=podman-restart.service`）落一次上限 |
| `h/start-vllm-ascend.sh` | `/usr/local/bin/` | vllm-ascend 容器创建/启动（幂等；2026-09-14 补的缺失重建路径，含 `--restart=always`） |
| `h/deploy-outline.sh` | `/opt/outline/` | outline 四容器部署（结尾调上面的上限脚本） |
| `verify-memory-limit.sh` | 不部署（在 h 上跑） | 内存上限语义自证：牺牲容器超限 → 内核 MEMCG OOM kill → 宿主存活 → restart 拉起 |
| `install.sh` | 不部署（在 m 上跑） | 幂等安装器：推送 + `restorecon` + `daemon-reload` + enable + 摘旧 cron 行 |

⚠️ 脚本必须落在 `/usr/local/bin`（SELinux `bin_t`）：放 `/root` 下是 `admin_home_t`，
SELinux Enforcing 会拒绝 `init_t` 执行，单元直接 203/EXEC 失败（2026-09-14 实测）。

## 用法

```sh
bash install.sh                            # 推送 + enable（改动前自动备份到 /root/h-hardening-backup-<ts>/）
ssh h 'bash -s' < verify-memory-limit.sh   # 内存上限语义自证（牺牲容器，不碰生产容器）

# h 机上的日常检查
ssh h 'systemctl list-timers container-healthcheck.timer; systemctl --failed; /usr/local/bin/container-mem-limits.sh'
```

`install.sh` 只写它自己管的路径，**不重启 gitea / NAS / syncthing，不重建 outline 容器**。
