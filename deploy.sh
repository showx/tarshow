#!/usr/bin/env bash
# tarshow — 远程项目备份、上传、解压，快速部署
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config}"
EXCLUDE_FILE="${EXCLUDE_FILE:-$SCRIPT_DIR/exclude}"

# ---------- 工具函数 ----------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "ERROR: $*"; exit 1; }

ssh_opts() {
  local host=$1 port=$2
  local opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$port")
  [[ -n "${SSH_KEY_PATH:-}" && -f "$SSH_KEY_PATH" ]] && opts+=(-i "$SSH_KEY_PATH")
  [[ -n "${SSH_EXTRA_OPTS:-}" ]] && read -r -a extra <<< "$SSH_EXTRA_OPTS" && opts+=("${extra[@]}")
  echo "${opts[@]}"
}

remote() {
  local user=$1 host=$2 port=$3
  shift 3
  # shellcheck disable=SC2046
  ssh $(ssh_opts "$host" "$port") "${user}@${host}" "$@"
}

scp_to_local() {
  local user=$1 host=$2 port=$3 remote_path=$4 local_path=$5
  # shellcheck disable=SC2046
  scp $(ssh_opts "$host" "$port") "${user}@${host}:${remote_path}" "$local_path"
}

scp_to_remote() {
  local user=$1 host=$2 port=$3 local_path=$4 remote_path=$5
  # shellcheck disable=SC2046
  scp $(ssh_opts "$host" "$port") "$local_path" "${user}@${host}:${remote_path}"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "配置文件不存在: $CONFIG_FILE\n  请先执行: cp config.example config"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  : "${SOURCE_HOST:?请在 config 中设置 SOURCE_HOST}"
  : "${SOURCE_USER:?请在 config 中设置 SOURCE_USER}"
  : "${SOURCE_PATH:?请在 config 中设置 SOURCE_PATH}"
  : "${DEST_HOST:?请在 config 中设置 DEST_HOST}"
  : "${DEST_USER:?请在 config 中设置 DEST_USER}"
  : "${DEST_PATH:?请在 config 中设置 DEST_PATH}"

  SOURCE_PORT="${SOURCE_PORT:-22}"
  DEST_PORT="${DEST_PORT:-22}"
  BACKUP_NAME="${BACKUP_NAME:-project}"
  KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
  BACKUP_DIR_ON_DEST="${BACKUP_DIR_ON_DEST:-/var/backups/deploy}"
  LOCAL_TMP_DIR="${LOCAL_TMP_DIR:-/tmp/tarshow}"
  DEPLOY_MODE="${DEPLOY_MODE:-backup}"
  CLEAN_DEST_BEFORE_EXTRACT="${CLEAN_DEST_BEFORE_EXTRACT:-false}"
  POST_DEPLOY_HOOK="${POST_DEPLOY_HOOK:-}"
}

build_exclude_args() {
  local args=""
  if [[ -f "$EXCLUDE_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line// /}"
      [[ -z "$line" ]] && continue
      args+=" --exclude=${line}"
    done < "$EXCLUDE_FILE"
  fi
  echo "$args"
}

timestamp() { date '+%Y%m%d_%H%M%S'; }

# ---------- 部署模式: stream（管道直传，最快）----------
deploy_stream() {
  log "模式: stream — 源 → 目标 管道直传（不保留 tar.gz）"

  local exclude_args
  exclude_args=$(build_exclude_args)

  local clean_cmd=""
  if [[ "$CLEAN_DEST_BEFORE_EXTRACT" == "true" ]]; then
    clean_cmd="find '${DEST_PATH}' -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true; "
  fi

  remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" \
    "mkdir -p '${DEST_PATH}' && ${clean_cmd}cat | tar xzf - -C '${DEST_PATH}'" \
    < <(remote "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" \
      "cd '${SOURCE_PATH}' && tar czf - ${exclude_args} .")

  run_post_deploy_hook
  log "stream 部署完成"
}

# ---------- 部署模式: backup（打包 → 上传 → 解压）----------
deploy_backup() {
  local ts archive_name
  ts=$(timestamp)
  archive_name="${BACKUP_NAME}_${ts}.tar.gz"

  local source_tmp="/tmp/${archive_name}"
  local local_tmp="${LOCAL_TMP_DIR}/${archive_name}"
  local dest_archive

  if [[ "$KEEP_BACKUPS" -gt 0 ]]; then
    dest_archive="${BACKUP_DIR_ON_DEST}/${archive_name}"
  else
    dest_archive="/tmp/${archive_name}"
  fi

  local exclude_args
  exclude_args=$(build_exclude_args)

  # 1. 源服务器打包
  log "步骤 1/4: 在源服务器打包 ${SOURCE_PATH}"
  remote "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" \
    "cd '${SOURCE_PATH}' && tar czf '${source_tmp}' ${exclude_args} ."
  log "  已生成: ${SOURCE_USER}@${SOURCE_HOST}:${source_tmp}"

  # 2. 下载到本机（中转）
  log "步骤 2/4: 下载到本机 ${local_tmp}"
  mkdir -p "$LOCAL_TMP_DIR"
  scp_to_local "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" "$source_tmp" "$local_tmp"

  # 3. 上传到目标服务器
  log "步骤 3/4: 上传到目标 ${DEST_USER}@${DEST_HOST}:${dest_archive}"
  if [[ "$KEEP_BACKUPS" -gt 0 ]]; then
    remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" "mkdir -p '${BACKUP_DIR_ON_DEST}'"
  fi
  scp_to_remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" "$local_tmp" "$dest_archive"

  # 4. 目标服务器解压
  log "步骤 4/4: 在目标服务器解压到 ${DEST_PATH}"
  local clean_cmd=""
  if [[ "$CLEAN_DEST_BEFORE_EXTRACT" == "true" ]]; then
    clean_cmd="find '${DEST_PATH}' -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true; "
  fi

  remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" \
    "mkdir -p '${DEST_PATH}' && ${clean_cmd}tar xzf '${dest_archive}' -C '${DEST_PATH}'"

  # 清理
  log "清理临时文件..."
  remote "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" "rm -f '${source_tmp}'" || true
  rm -f "$local_tmp"

  if [[ "$KEEP_BACKUPS" -eq 0 ]]; then
    remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" "rm -f '${dest_archive}'" || true
  else
    prune_old_backups
  fi

  run_post_deploy_hook
  log "backup 部署完成 → ${DEST_PATH}"
  [[ "$KEEP_BACKUPS" -gt 0 ]] && log "备份保留: ${dest_archive}"
}

prune_old_backups() {
  log "保留最近 ${KEEP_BACKUPS} 份备份..."
  remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" \
    "ls -1t '${BACKUP_DIR_ON_DEST}/${BACKUP_NAME}'_*.tar.gz 2>/dev/null \
     | tail -n +$((KEEP_BACKUPS + 1)) \
     | xargs -r rm -f" || true
}

run_post_deploy_hook() {
  [[ -z "$POST_DEPLOY_HOOK" ]] && return 0
  log "执行部署后钩子: ${POST_DEPLOY_HOOK}"
  remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" "bash '${POST_DEPLOY_HOOK}'"
}

show_help() {
  cat <<'EOF'
tarshow — 远程项目备份、上传、解压部署工具

用法:
  ./deploy.sh              执行部署（读取 ./config）
  ./deploy.sh --check      测试 SSH 连通性
  ./deploy.sh --rollback   回滚到上一份备份（仅 backup 模式 + KEEP_BACKUPS > 0）
  CONFIG_FILE=/path/to/config ./deploy.sh

环境变量:
  CONFIG_FILE   配置文件路径（默认 ./config）
  EXCLUDE_FILE  排除规则文件（默认 ./exclude）

EOF
}

check_connectivity() {
  log "测试源服务器 ${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_PORT} ..."
  remote "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" "echo OK && test -d '${SOURCE_PATH}'" \
    || die "无法连接源服务器或目录不存在: ${SOURCE_PATH}"

  log "测试目标服务器 ${DEST_USER}@${DEST_HOST}:${DEST_PORT} ..."
  remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" "echo OK" \
    || die "无法连接目标服务器"

  log "连通性检查通过"
}

deploy_rollback() {
  [[ "$KEEP_BACKUPS" -gt 0 ]] || die "回滚需要 KEEP_BACKUPS > 0"

  log "查找最新备份..."
  local latest
  latest=$(remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" \
    "ls -1t '${BACKUP_DIR_ON_DEST}/${BACKUP_NAME}'_*.tar.gz 2>/dev/null | head -1") \
    || die "未找到备份文件"

  [[ -z "$latest" ]] && die "未找到备份文件"

  log "回滚到: ${latest}"
  local clean_cmd=""
  if [[ "$CLEAN_DEST_BEFORE_EXTRACT" == "true" ]]; then
    clean_cmd="find '${DEST_PATH}' -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true; "
  fi

  remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" \
    "mkdir -p '${DEST_PATH}' && ${clean_cmd}tar xzf '${latest}' -C '${DEST_PATH}'"

  run_post_deploy_hook
  log "回滚完成"
}

# ---------- 入口 ----------
main() {
  case "${1:-}" in
    -h|--help|help) show_help; exit 0 ;;
  esac

  load_config

  case "${1:-}" in
    --check)   check_connectivity; exit 0 ;;
    --rollback) deploy_rollback; exit 0 ;;
  esac

  log "========== tarshow 开始部署 =========="
  log "源: ${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_PATH}"
  log "目标: ${DEST_USER}@${DEST_HOST}:${DEST_PATH}"
  log "模式: ${DEPLOY_MODE}"

  check_connectivity

  case "$DEPLOY_MODE" in
    stream) deploy_stream ;;
    backup) deploy_backup ;;
    *) die "未知 DEPLOY_MODE: ${DEPLOY_MODE}（可选: backup | stream）" ;;
  esac

  log "========== 部署成功 =========="
}

main "$@"
