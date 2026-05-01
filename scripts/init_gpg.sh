#!/bin/bash
# init_gpg.sh - 建立隔離的 GPG 環境，匯入 Ubuntu keyring keys
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"
GPG_HOME="$DATA_DIR/gnupg"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat << EOF
用法: $0 <指令>

指令:
  init      建立隔離 GPG 環境並匯入 Ubuntu keyring keys
  status    顯示目前 GPG 環境狀態
  clean     清除 GPG 環境

範例:
  $0 init
  $0 status

EOF
    exit 1
}

cmd_init() {
    log_info "初始化隔離 GPG 環境..."

    # 建立目錄
    mkdir -p "$GPG_HOME"
    chmod 700 "$GPG_HOME"

    # 尋找 Ubuntu keyring keys
    keyring_paths=(
        "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
        "/usr/share/keyrings/ubuntu-releases-keyring.gpg"
        "/usr/share/keyrings/ubuntu-archive-keyring.list"
        "/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg"
    )

    imported=0

    # 匯入各個 keyring
    for keyring in "${keyring_paths[@]}"; do
        if [[ -f "$keyring" ]]; then
            log_info "匯入: $keyring"
            if GNUPGHOME="$GPG_HOME" gpg --no-default-keyring \
                --keyring="$keyring" \
                --export 2>/dev/null | \
                GNUPGHOME="$GPG_HOME" gpg --no-default-keyring \
                --keyring="$GPG_HOME/trustedkeys.gpg" \
                --import 2>/dev/null; then
                imported=$((imported + 1))
            else
                log_warn "匯入失敗或無可用金鑰: $keyring"
            fi
        fi
    done

    # 另外嘗試直接從 apt 匯出 keyring
    apt_keyring="/etc/apt/trusted.gpg"
    if [[ -f "$apt_keyring" ]]; then
        log_info "匯入: $apt_keyring"
        if GNUPGHOME="$GPG_HOME" gpg --no-default-keyring \
            --keyring="$apt_keyring" \
            --export 2>/dev/null | \
            GNUPGHOME="$GPG_HOME" gpg --no-default-keyring \
            --keyring="$GPG_HOME/trustedkeys.gpg" \
            --import 2>/dev/null; then
            imported=$((imported + 1))
        fi
    fi

    # 也匯入 /etc/apt/trusted.gpg.d/ 下的額外 keys
    extra_keys_dir="/etc/apt/trusted.gpg.d"
    if [[ -d "$extra_keys_dir" ]]; then
        for keyring in "$extra_keys_dir"/*.gpg; do
            [[ -f "$keyring" ]] || continue
            log_info "匯入額外 key: $keyring"
            GNUPGHOME="$GPG_HOME" gpg --no-default-keyring \
                --keyring="$keyring" \
                --export 2>/dev/null | \
                GNUPGHOME="$GPG_HOME" gpg --no-default-keyring \
                --keyring="$GPG_HOME/trustedkeys.gpg" \
                --import 2>/dev/null || true
        done
    fi

    # 列出已匯入的金鑰
    echo ""
    log_info "GPG 環境已建立: $GPG_HOME"
    echo ""
    echo "已匯入的金鑰:"
    GNUPGHOME="$GPG_HOME" gpg --no-default-keyring \
        --keyring="$GPG_HOME/trustedkeys.gpg" \
        --list-keys 2>/dev/null | grep -E "^(pub|sub|uid)" | head -20 || echo "  (無金鑰)"

    echo ""
    echo "使用方式: 設定 GNUPGHOME=$GPG_HOME"
}

cmd_status() {
    if [[ ! -d "$GPG_HOME" ]]; then
        echo "GPG 環境尚未初始化: $GPG_HOME"
        exit 1
    fi

    echo "GPG 環境: $GPG_HOME"
    echo ""
    echo "已匯入的金鑰:"
    GNUPGHOME="$GPG_HOME" gpg --no-default-keyring \
        --keyring="$GPG_HOME/trustedkeys.gpg" \
        --list-keys 2>/dev/null | grep -E "^(pub|sub|uid)" | head -20 || echo "  (無金鑰)"
}

cmd_clean() {
    log_info "清除 GPG 環境..."
    rm -rf "$GPG_HOME"
    log_info "已清除: $GPG_HOME"
}

COMMAND="${1:-}"
shift 2>/dev/null || true

case "$COMMAND" in
    init)
        cmd_init
        ;;
    status)
        cmd_status
        ;;
    clean)
        cmd_clean
        ;;
    *)
        log_error "未知指令: $COMMAND"
        usage
        ;;
esac
