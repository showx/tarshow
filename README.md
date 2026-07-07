# tarshow

远程项目目录自动打包为 `tar.gz`、上传到另一台服务器并解压，用于快速部署。

## 流程

```
源服务器                         本机（可选中转）              目标服务器
┌─────────────┐                ┌──────────┐                ┌─────────────┐
│ SOURCE_PATH │ ── tar.gz ──►  │  /tmp    │ ── scp ──────► │ DEST_PATH   │
│  项目目录    │                │          │                │  解压部署    │
└─────────────┘                └──────────┘                └─────────────┘
```

也支持 **stream 模式**：源服务器直接管道传到目标，不落地备份文件，速度最快。

仅备份到本机时，远程目录直接管道下载为本地 `tar.gz`，无需配置目标服务器：

```
源服务器                         本机
┌─────────────┐                ┌──────────────┐
│ SOURCE_PATH │ ── tar.gz ──►  │ LOCAL_BACKUP │
└─────────────┘                └──────────────┘
```

本地上传到源服务器（`push`），与 `pull` 方向相反：

```
本机                             源服务器
┌──────────────┐                ┌─────────────┐
│ LOCAL_SOURCE │ ── tar.gz ──►  │ SOURCE_PATH │
└──────────────┘                └─────────────┘
```

## 快速开始

### 方式 A：无配置，直接传参（推荐临时使用）

```bash
chmod +x deploy.sh

# 备份远程目录到本机
./deploy.sh pull root@192.168.1.10:/var/www/myproject
./deploy.sh pull root@10.0.0.1:/var/www/app -o ~/backups -p 2222

# 上传本地目录到远程服务器
./deploy.sh push ./dist root@192.168.1.10:/var/www/myproject

# 上传已有 tar.gz 备份包并解压（如 pull 下载的备份）
./deploy.sh push ./backups/www_20260707_141949.tar.gz root@192.168.1.10:/var/www/myproject

# 指定本地目录 + 解压前清空远程目录
./deploy.sh push root@10.0.0.1:/var/www/app -f ./dist --clean

# 同步部署到另一台服务器（管道直传，最快）
./deploy.sh sync root@10.0.0.1:/var/www/app root@10.0.0.2:/var/www/app

# 经 tar.gz 中转部署
./deploy.sh sync root@10:/var/www/app root@20:/var/www/app --backup --keep 3
```

地址格式：`user@host:/绝对路径`，无需 `config` 文件。

### 方式 B：配置文件（推荐固定环境）

```bash
# 1. 复制配置
cp config.example config
cp exclude.example exclude

# 2. 编辑 config，填写源/目标服务器信息
vim config

# 3. 确保本机可以 SSH 免密登录两台服务器
ssh-copy-id -i ~/.ssh/id_rsa root@源服务器IP
ssh-copy-id -i ~/.ssh/id_rsa root@目标服务器IP

# 4. 测试连通性
chmod +x deploy.sh
./deploy.sh --check

# 5. 执行部署
./deploy.sh
```

## 命令一览

| 命令 | 说明 | 需要 config |
|------|------|-------------|
| `pull SOURCE [选项]` | 备份远程目录到本机 | 否 |
| `push [LOCAL] DEST [选项]` | 上传本地目录到远程 | 否 |
| `sync SOURCE DEST [选项]` | 同步部署 | 否 |
| `./deploy.sh` | 按 config 部署 | 是 |
| `./deploy.sh --backup` | 按 config 本地备份 | 是 |
| `./deploy.sh --push` | 按 config 上传到源服务器 | 是 |
| `./deploy.sh --check` | 测试连通性 | 是 |
| `./deploy.sh --rollback` | 回滚 | 是 |

`pull` / `push` / `sync` 若存在 `config`，会先读取作为默认值，命令行参数优先覆盖。

## 配置说明

| 配置项 | 说明 |
|--------|------|
| `SOURCE_*` | 源服务器地址、用户、端口、项目路径 |
| `DEST_*` | 目标服务器地址、用户、端口、部署路径 |
| `DEPLOY_MODE` | `backup` / `stream` / `local`（仅备份到本机）/ `push`（上传到源服务器） |
| `LOCAL_BACKUP_DIR` | 本地备份存放目录（默认 `./backups`） |
| `LOCAL_SOURCE_PATH` | 本地上传源目录（`push` 模式，默认 `.`） |
| `KEEP_LOCAL_BACKUPS` | 本地保留备份份数，0 = 不自动清理 |
| `KEEP_BACKUPS` | 目标服务器保留备份份数，0 = 解压后删除 |
| `CLEAN_DEST_BEFORE_EXTRACT` | 解压前是否清空目标目录 |
| `POST_DEPLOY_HOOK` | 解压后在目标服务器执行的脚本（如重启服务） |

配置文件模式补充：

```bash
./deploy.sh --backup     # 按 config 本地备份
./deploy.sh --push       # 按 config 上传到源服务器
./deploy.sh --check      # 测试 SSH 和目录
./deploy.sh --rollback   # 回滚到最新备份（需 KEEP_BACKUPS > 0）
./deploy.sh --help       # 帮助
```

## 部署后钩子示例

在目标服务器创建 `/opt/scripts/post-deploy.sh`：

```bash
#!/bin/bash
set -e
cd /var/www/myproject
# PHP
# composer install --no-dev -o
# php artisan migrate --force
# systemctl reload php-fpm nginx
echo "post-deploy done"
```

然后在 `config` 中设置：

```
POST_DEPLOY_HOOK="/opt/scripts/post-deploy.sh"
```

## 前置条件

- 本机已安装 `bash`、`ssh`、`scp`
- 本机可 SSH 免密登录源服务器；完整部署时还需登录目标服务器
- 源服务器已安装 `tar`，目标服务器已安装 `tar`
- 建议在 Linux / macOS / WSL / Git Bash 下运行

## 模式对比

| | backup | stream | local | push |
|---|--------|--------|-------|------|
| 速度 | 较慢（三次传输） | 最快（一次管道） | 较快（管道到本机） | 较快（管道到远程） |
| 保留备份 | 目标服务器，可回滚 | 不支持 | 本机，可手动保留 | 不支持 |
| 需要目标服务器 | 是 | 是 | 否 | 否 |
| 适用场景 | 生产部署、回滚 | 开发/测试快速同步 | 定期备份、归档 | 本地开发完上传部署 |
