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
  [[ -f "$CONFIG_FILE" ]] || die "配置文件不存在: $CONFIG_FILE\n  请先执行: cp config.example config\n  或使用无配置模式: ./deploy.sh pull user@host:/path"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  apply_defaults
}

apply_defaults() {
  SOURCE_PORT="${SOURCE_PORT:-22}"
  DEST_PORT="${DEST_PORT:-22}"
  BACKUP_NAME="${BACKUP_NAME:-project}"
  KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
  BACKUP_DIR_ON_DEST="${BACKUP_DIR_ON_DEST:-/var/backups/deploy}"
  LOCAL_TMP_DIR="${LOCAL_TMP_DIR:-/tmp/tarshow}"
  LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-./backups}"
  KEEP_LOCAL_BACKUPS="${KEEP_LOCAL_BACKUPS:-5}"
  DEPLOY_MODE="${DEPLOY_MODE:-backup}"
  CLEAN_DEST_BEFORE_EXTRACT="${CLEAN_DEST_BEFORE_EXTRACT:-false}"
  POST_DEPLOY_HOOK="${POST_DEPLOY_HOOK:-}"
  SSH_KEY_PATH="${SSH_KEY_PATH:-}"
  SSH_EXTRA_OPTS="${SSH_EXTRA_OPTS:-}"
}

load_config_optional() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  apply_defaults
}

parse_remote_spec() {
  local spec=$1 prefix=$2
  if [[ ! "$spec" =~ ^([^@/]+@)?([^:]+):(.+)$ ]]; then
    die "无效的远程地址: $spec（格式: user@host:/绝对路径）"
  fi
  local user_part="${BASH_REMATCH[1]}" host="${BASH_REMATCH[2]}" path="${BASH_REMATCH[3]}"
  local user="${user_part%@}"
  user="${user:-root}"
  [[ "$path" == /* ]] || die "路径必须是绝对路径: $path"

  eval "${prefix}_USER=\"$user\""
  eval "${prefix}_HOST=\"$host\""
  eval "${prefix}_PATH=\"$path\""
}

require_dest_config() {
  : "${DEST_HOST:?请在 config 中设置 DEST_HOST（local 模式不需要）}"
  : "${DEST_USER:?请在 config 中设置 DEST_USER}"
  : "${DEST_PATH:?请在 config 中设置 DEST_PATH}"
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

# ---------- 模式: local（仅备份到本机）----------
deploy_local() {
  local ts archive_name local_path exclude_args
  ts=$(timestamp)
  archive_name="${BACKUP_NAME}_${ts}.tar.gz"
  local_path="${LOCAL_BACKUP_DIR}/${archive_name}"
  exclude_args=$(build_exclude_args)

  mkdir -p "$LOCAL_BACKUP_DIR"

  log "模式: local — 远程 ${SOURCE_PATH} → 本地 ${local_path}"
  log "步骤 1/1: 打包并下载..."
  remote "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" \
    "cd '${SOURCE_PATH}' && tar czf - ${exclude_args} ." > "$local_path"

  prune_local_backups
  log "本地备份完成: ${local_path} ($(du -h "$local_path" | cut -f1))"
}

prune_local_backups() {
  [[ "$KEEP_LOCAL_BACKUPS" -gt 0 ]] || return 0
  log "保留最近 ${KEEP_LOCAL_BACKUPS} 份本地备份..."
  ls -1t "${LOCAL_BACKUP_DIR}/${BACKUP_NAME}"_*.tar.gz 2>/dev/null \
    | tail -n +$((KEEP_LOCAL_BACKUPS + 1)) \
    | xargs -r rm -f 2>/dev/null || true
}

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

无配置模式（直接传参，无需 config 文件）:
  ./deploy.sh pull  SOURCE [选项]          备份远程目录到本机
  ./deploy.sh sync  SOURCE DEST [选项]     同步部署（SOURCE → DEST）

  SOURCE / DEST 格式: user@host:/绝对路径
  例: root@192.168.1.10:/var/www/myproject

  pull 选项:
    -o, --output DIR     本地保存目录（默认 ./backups）
    -n, --name NAME      备份文件名前缀（默认取路径末段）
    -p, --port PORT      SSH 端口（默认 22）
    -i, --identity FILE  SSH 私钥
    -E, --exclude FILE   排除规则文件（默认 ./exclude，不存在则跳过）
    --keep N             本地保留最近 N 份（默认 5，0=不清理）

  sync 选项:
    --stream             管道直传（默认，最快）
    --backup             经 tar.gz 中转（可配合 --keep）
    --clean              解压前清空目标目录
    -p, --port PORT       源 SSH 端口
    -P, --dest-port PORT  目标 SSH 端口
    -i, --identity FILE   SSH 私钥
    -E, --exclude FILE    排除规则文件
    --keep N              目标保留备份份数（仅 --backup，默认 0）

  示例:
    ./deploy.sh pull root@10.0.0.1:/var/www/app -o ~/backups
    ./deploy.sh sync root@10:/var/www/app root@20:/var/www/app --stream
    ./deploy.sh sync root@10:/data root@20:/data --backup --keep 3

配置文件模式:
  ./deploy.sh              按 config 中 DEPLOY_MODE 执行
  ./deploy.sh --backup     仅备份到本机
  ./deploy.sh --check      测试 SSH 连通性
  ./deploy.sh --rollback   回滚到上一份备份

环境变量:
  CONFIG_FILE   配置文件路径（默认 ./config，CLI 模式下可选作默认值）
  EXCLUDE_FILE  排除规则文件（默认 ./exclude）

EOF
}

check_connectivity() {
  log "测试源服务器 ${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_PORT} ..."
  remote "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" "echo OK && test -d '${SOURCE_PATH}'" \
    || die "无法连接源服务器或目录不存在: ${SOURCE_PATH}"

  if [[ "$DEPLOY_MODE" != "local" ]]; then
    require_dest_config
    log "测试目标服务器 ${DEST_USER}@${DEST_HOST}:${DEST_PORT} ..."
    remote "$DEST_USER" "$DEST_HOST" "$DEST_PORT" "echo OK" \
      || die "无法连接目标服务器"
  fi

  log "连通性检查通过"
}

deploy_rollback() {
  require_dest_config
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

# ---------- 无配置 CLI 模式 ----------
run_cli_pull() {
  local source_spec="" out_dir="" port="" key="" name="" keep=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--output)   out_dir=$2; shift 2 ;;
      -n|--name)     name=$2; shift 2 ;;
      -p|--port)     port=$2; shift 2 ;;
      -i|--identity) key=$2; shift 2 ;;
      -E|--exclude)  EXCLUDE_FILE=$2; shift 2 ;;
      --keep)        keep=$2; shift 2 ;;
      -h|--help)     show_help; exit 0 ;;
      -*)            die "未知选项: $1" ;;
      *)
        [[ -z "$source_spec" ]] && source_spec=$1 || die "多余参数: $1"
        shift
        ;;
    esac
  done
  [[ -n "$source_spec" ]] || die "用法: ./deploy.sh pull user@host:/path [选项]"

  load_config_optional
  parse_remote_spec "$source_spec" SOURCE
  [[ -n "$port" ]] && SOURCE_PORT=$port
  [[ -n "$key" ]] && SSH_KEY_PATH=$key
  [[ -n "$out_dir" ]] && LOCAL_BACKUP_DIR=$out_dir
  [[ -n "$keep" ]] && KEEP_LOCAL_BACKUPS=$keep
  if [[ -n "$name" ]]; then
    BACKUP_NAME=$name
  else
    BACKUP_NAME=$(basename "${SOURCE_PATH%/}")
  fi

  DEPLOY_MODE="local"
  log "========== pull: ${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_PATH} → ${LOCAL_BACKUP_DIR} =========="
  check_connectivity
  deploy_local
  log "========== 本地备份成功 =========="
}

run_cli_sync() {
  local source_spec="" dest_spec="" port="" dest_port="" key="" keep="" mode="stream"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stream)       mode="stream"; shift ;;
      --backup)       mode="backup"; shift ;;
      --clean)        CLEAN_DEST_BEFORE_EXTRACT="true"; shift ;;
      -p|--port)      port=$2; shift 2 ;;
      -P|--dest-port) dest_port=$2; shift 2 ;;
      -i|--identity)  key=$2; shift 2 ;;
      -E|--exclude)   EXCLUDE_FILE=$2; shift 2 ;;
      --keep)         keep=$2; shift 2 ;;
      -h|--help)      show_help; exit 0 ;;
      -* )            die "未知选项: $1" ;;
      *)
        if [[ -z "$source_spec" ]]; then
          source_spec=$1
        elif [[ -z "$dest_spec" ]]; then
          dest_spec=$1
        else
          die "多余参数: $1"
        fi
        shift
        ;;
    esac
  done
  [[ -n "$source_spec" && -n "$dest_spec" ]] \
    || die "用法: ./deploy.sh sync user@host:/src user@host:/dest [选项]"

  load_config_optional
  parse_remote_spec "$source_spec" SOURCE
  parse_remote_spec "$dest_spec" DEST
  [[ -n "$port" ]] && SOURCE_PORT=$port
  [[ -n "$dest_port" ]] && DEST_PORT=$dest_port
  [[ -n "$key" ]] && SSH_KEY_PATH=$key
  [[ -n "$keep" ]] && KEEP_BACKUPS=$keep
  DEPLOY_MODE=$mode
  BACKUP_NAME="${BACKUP_NAME:-$(basename "${SOURCE_PATH%/}")}"
  [[ "$mode" == "backup" && -z "$keep" ]] && KEEP_BACKUPS=0

  log "========== sync: ${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_PATH} → ${DEST_USER}@${DEST_HOST}:${DEST_PATH} (${mode}) =========="
  check_connectivity
  case "$DEPLOY_MODE" in
    stream) deploy_stream ;;
    backup) deploy_backup ;;
    *) die "未知模式: $DEPLOY_MODE" ;;
  esac
  log "========== 部署成功 =========="
}

# ---------- 入口 ----------
main() {
  local action="${1:-}"

  case "$action" in
    -h|--help|help) show_help; exit 0 ;;
    pull) run_cli_pull "$@"; exit 0 ;;
    sync) run_cli_sync "$@"; exit 0 ;;
  esac

  load_config

  : "${SOURCE_HOST:?请在 config 中设置 SOURCE_HOST}"
  : "${SOURCE_USER:?请在 config 中设置 SOURCE_USER}"
  : "${SOURCE_PATH:?请在 config 中设置 SOURCE_PATH}"

  case "$action" in
    --backup|--pull) DEPLOY_MODE="local" ;;
  esac

  case "$action" in
    --check)    check_connectivity; exit 0 ;;
    --rollback) deploy_rollback; exit 0 ;;
  esac

  if [[ "$DEPLOY_MODE" == "local" ]]; then
    log "========== tarshow 开始本地备份 =========="
    log "源: ${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_PATH}"
    log "本地目录: ${LOCAL_BACKUP_DIR}"
  else
    require_dest_config
    log "========== tarshow 开始部署 =========="
    log "源: ${SOURCE_USER}@${SOURCE_HOST}:${SOURCE_PATH}"
    log "目标: ${DEST_USER}@${DEST_HOST}:${DEST_PATH}"
    log "模式: ${DEPLOY_MODE}"
  fi

  check_connectivity

  case "$DEPLOY_MODE" in
    local)  deploy_local ;;
    stream) deploy_stream ;;
    backup) deploy_backup ;;
    *) die "未知 DEPLOY_MODE: ${DEPLOY_MODE}（可选: backup | stream | local）" ;;
  esac

  if [[ "$DEPLOY_MODE" == "local" ]]; then
    log "========== 本地备份成功 =========="
  else
    log "========== 部署成功 =========="
  fi
}

main "$@"
