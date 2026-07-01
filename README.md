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

## 快速开始

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

## 配置说明

| 配置项 | 说明 |
|--------|------|
| `SOURCE_*` | 源服务器地址、用户、端口、项目路径 |
| `DEST_*` | 目标服务器地址、用户、端口、部署路径 |
| `DEPLOY_MODE` | `backup`（保留 tar.gz）或 `stream`（管道直传） |
| `KEEP_BACKUPS` | 目标服务器保留备份份数，0 = 解压后删除 |
| `CLEAN_DEST_BEFORE_EXTRACT` | 解压前是否清空目标目录 |
| `POST_DEPLOY_HOOK` | 解压后在目标服务器执行的脚本（如重启服务） |

## 命令

```bash
./deploy.sh              # 执行部署
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
- 本机可 SSH 免密登录**源**和**目标**两台服务器
- 源服务器已安装 `tar`，目标服务器已安装 `tar`
- 建议在 Linux / macOS / WSL / Git Bash 下运行

## 两种模式对比

| | backup | stream |
|---|--------|--------|
| 速度 | 较慢（三次传输） | 最快（一次管道） |
| 保留备份 | 支持，可回滚 | 不支持 |
| 适用场景 | 生产环境、需要回滚 | 开发/测试快速同步 |
