#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# 固定設定
# ============================================================

CONFIG_FILE="/etc/app-deploy/app.conf"

# ============================================================
# 共通関数
# ============================================================

log() {
    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*"
}

error() {
    printf '[%s] ERROR: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$*" >&2
}

require_variable() {
    local variable_name="$1"

    if [[ -z "${!variable_name:-}" ]]; then
        error "設定値がありません: ${variable_name}"
        exit 1
    fi
}

# ============================================================
# 設定ファイル読み込み
# ============================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    error "設定ファイルが見つかりません: $CONFIG_FILE"
    exit 1
fi

# 設定ファイルはroot所有・一般ユーザー書き込み不可にすること
# shellcheck source=/etc/app-deploy/app.conf
source "$CONFIG_FILE"

# 必須設定
require_variable "LIBERTY_HOME"
require_variable "SERVER_NAME"
require_variable "APP_WAR"
require_variable "APP_OWNER"
require_variable "APP_GROUP"
require_variable "BACKUP_DIR"
require_variable "LOCK_FILE"

# 任意設定の初期値
HEALTH_URL="${HEALTH_URL:-}"
HEALTH_CHECK_COUNT="${HEALTH_CHECK_COUNT:-30}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-2}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-5}"
BACKUP_RETAIN_COUNT="${BACKUP_RETAIN_COUNT:-10}"

SERVER_COMMAND="${LIBERTY_HOME}/bin/server"

# ============================================================
# 引数確認
# ============================================================

SOURCE_WAR="${1:-}"

if [[ -z "$SOURCE_WAR" ]]; then
    error "WARファイルが指定されていません。"
    echo "使用方法: $0 <送信済みWARファイル>"
    exit 1
fi

if [[ ! -f "$SOURCE_WAR" ]]; then
    error "指定されたWARファイルが見つかりません: $SOURCE_WAR"
    exit 1
fi

if [[ "${SOURCE_WAR,,}" != *.war ]]; then
    error "指定されたファイルはWARファイルではありません: $SOURCE_WAR"
    exit 1
fi

if [[ ! -x "$SERVER_COMMAND" ]]; then
    error "Libertyのserverコマンドが実行できません: $SERVER_COMMAND"
    exit 1
fi

if ! [[ "$HEALTH_CHECK_COUNT" =~ ^[0-9]+$ ]]; then
    error "HEALTH_CHECK_COUNTは0以上の整数で指定してください。"
    exit 1
fi

if ! [[ "$HEALTH_CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
    error "HEALTH_CHECK_INTERVALは0以上の整数で指定してください。"
    exit 1
fi

if ! [[ "$HEALTH_CHECK_TIMEOUT" =~ ^[0-9]+$ ]]; then
    error "HEALTH_CHECK_TIMEOUTは0以上の整数で指定してください。"
    exit 1
fi

if ! [[ "$BACKUP_RETAIN_COUNT" =~ ^[0-9]+$ ]]; then
    error "BACKUP_RETAIN_COUNTは0以上の整数で指定してください。"
    exit 1
fi

# ============================================================
# デプロイ用情報
# ============================================================

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

APP_WAR_NAME="$(basename "$APP_WAR")"
APP_NAME="${APP_WAR_NAME%.war}"

BACKUP_WAR="${BACKUP_DIR}/${APP_NAME}_${TIMESTAMP}.war"

BACKUP_CREATED="false"
NEW_WAR_INSTALLED="false"

# ============================================================
# ディレクトリ準備
# ============================================================

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$APP_WAR")"
mkdir -p "$(dirname "$LOCK_FILE")"

# ============================================================
# 二重デプロイ防止
# ============================================================

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    error "別のデプロイ処理が実行中です。"
    exit 1
fi

# ============================================================
# ロールバック処理
# ============================================================

rollback() {
    error "デプロイに失敗したため、ロールバックを開始します。"

    log "Libertyを停止します。"

    if ! "$SERVER_COMMAND" stop "$SERVER_NAME"; then
        error "ロールバック時のLiberty停止に失敗しました。処理を継続します。"
    fi

    if [[ "$BACKUP_CREATED" == "true" && -f "$BACKUP_WAR" ]]; then
        log "旧WARを復元します: $BACKUP_WAR"

        if ! install \
            -o "$APP_OWNER" \
            -g "$APP_GROUP" \
            -m 0644 \
            "$BACKUP_WAR" \
            "$APP_WAR"; then

            error "旧WARの復元に失敗しました。"
            return 1
        fi
    else
        error "復元可能なバックアップWARがありません。"

        if [[ "$NEW_WAR_INSTALLED" == "true" && -f "$APP_WAR" ]]; then
            log "新しく配置したWARを削除します。"
            rm -f "$APP_WAR"
        fi
    fi

    log "Libertyを再起動します。"

    if ! "$SERVER_COMMAND" start "$SERVER_NAME"; then
        error "ロールバック後のLiberty起動に失敗しました。"
        return 1
    fi

    error "ロールバックが完了しました。"
}

# ============================================================
# 起動確認
# ============================================================

check_application_started() {
    local attempt

    for ((attempt = 1; attempt <= HEALTH_CHECK_COUNT; attempt++)); do
        log "起動確認中: ${attempt}/${HEALTH_CHECK_COUNT}"

        if [[ -n "$HEALTH_URL" ]]; then
            if curl \
                --fail \
                --silent \
                --show-error \
                --max-time "$HEALTH_CHECK_TIMEOUT" \
                "$HEALTH_URL" >/dev/null 2>&1; then

                return 0
            fi
        else
            if "$SERVER_COMMAND" status "$SERVER_NAME" \
                >/dev/null 2>&1; then

                return 0
            fi
        fi

        sleep "$HEALTH_CHECK_INTERVAL"
    done

    return 1
}

# ============================================================
# 古いバックアップ削除
# ============================================================

remove_old_backups() {
    if ((BACKUP_RETAIN_COUNT <= 0)); then
        return 0
    fi

    mapfile -t backup_files < <(
        find "$BACKUP_DIR" \
            -maxdepth 1 \
            -type f \
            -name "${APP_NAME}_*.war" \
            -printf '%T@ %p\n' |
        sort -nr |
        awk '{print $2}'
    )

    if ((${#backup_files[@]} <= BACKUP_RETAIN_COUNT)); then
        return 0
    fi

    local index

    for ((
        index = BACKUP_RETAIN_COUNT;
        index < ${#backup_files[@]};
        index++
    )); do
        log "古いバックアップを削除します: ${backup_files[$index]}"
        rm -f -- "${backup_files[$index]}"
    done
}

# ============================================================
# デプロイ開始
# ============================================================

log "============================================================"
log "アプリケーションデプロイ開始"
log "============================================================"
log "Libertyサーバ : $SERVER_NAME"
log "送信WAR       : $SOURCE_WAR"
log "配置先        : $APP_WAR"
log "バックアップ先: $BACKUP_WAR"

# ============================================================
# 1. 現在のWARをバックアップ
# ============================================================

if [[ -f "$APP_WAR" ]]; then
    log "[1/5] 現在のWARをバックアップします。"

    if ! cp -a "$APP_WAR" "$BACKUP_WAR"; then
        error "WARファイルのバックアップに失敗しました。"
        exit 1
    fi

    BACKUP_CREATED="true"

    log "バックアップを作成しました: $BACKUP_WAR"
else
    log "[1/5] 現在のWARは存在しません。バックアップを省略します。"
fi

# ============================================================
# 2. Liberty停止
# ============================================================

log "[2/5] Libertyを停止します。"

if ! "$SERVER_COMMAND" stop "$SERVER_NAME"; then
    error "Libertyの停止に失敗しました。"
    exit 1
fi

# ============================================================
# 3. 新しいWARを配置
# ============================================================

log "[3/5] 新しいWARを配置します。"

if ! install \
    -o "$APP_OWNER" \
    -g "$APP_GROUP" \
    -m 0644 \
    "$SOURCE_WAR" \
    "$APP_WAR"; then

    error "新しいWARの配置に失敗しました。"

    rollback || true
    exit 1
fi

NEW_WAR_INSTALLED="true"

log "WARを配置しました: $APP_WAR"

# ============================================================
# 4. Liberty起動
# ============================================================

log "[4/5] Libertyを起動します。"

if ! "$SERVER_COMMAND" start "$SERVER_NAME"; then
    error "Libertyの起動に失敗しました。"

    rollback || true
    exit 1
fi

# ============================================================
# 5. 起動確認
# ============================================================

log "[5/5] アプリケーションの起動を確認します。"

if ! check_application_started; then
    error "制限時間内にアプリケーションの起動を確認できませんでした。"

    rollback || true
    exit 1
fi

log "アプリケーションの起動を確認しました。"

# ============================================================
# 後処理
# ============================================================

log "AWSサーバの一時WARを削除します: $SOURCE_WAR"
rm -f -- "$SOURCE_WAR"

remove_old_backups

log "============================================================"
log "デプロイが正常に完了しました。"
log "============================================================"

if [[ "$BACKUP_CREATED" == "true" ]]; then
    log "バックアップWAR: $BACKUP_WAR"
fi

exit 0