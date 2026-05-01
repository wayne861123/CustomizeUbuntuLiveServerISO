#!/bin/bash
# prepare_iso.sh - 掛載來源 ISO 並複製內容到 custom-iso 目錄
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"
CONFIG_FILE="$DATA_DIR/config.conf"

# Directories
SOURCE_ISO_DIR="$PROJECT_DIR/source-iso"
CUSTOM_ISO_DIR="$PROJECT_DIR/custom-iso"

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
用法: $0 [選項]

說明:
  掛載來源 ISO 並複製內容到 custom-iso 目錄。

  會讀取 data/config.conf 中的 SOURCE_ISO 設定。
  掛載點: source-iso/
  複製目標: custom-iso/

選項:
  --iso <path>    直接指定 ISO 路徑（忽略 config）
  --unmount       卸載已掛載的 ISO 並清除暫存目錄
  --clean         清除 custom-iso 目錄（保留 source-iso）
  -h, --help      顯示說明

範例:
  $0                    # 使用 config.conf 中的設定
  $0 --iso /path/to.iso # 指定 ISO 路徑
  $0 --unmount          # 卸載並清除
  $0 --clean            # 清除 custom-iso

EOF
    exit 1
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi

    if [[ -z "$SOURCE_ISO" ]]; then
        log_error "未指定來源 ISO，請使用 --iso 或在 init.sh 中設定"
        exit 1
    fi

    if [[ ! -f "$SOURCE_ISO" ]]; then
        log_error "ISO 檔案不存在: $SOURCE_ISO"
        exit 1
    fi
}

check_mounted() {
    if mountpoint -q "$SOURCE_ISO_DIR" 2>/dev/null; then
        return 0
    fi
    return 1
}

do_mount() {
    log_info "掛載 ISO: $SOURCE_ISO"

    # Create mount point
    mkdir -p "$SOURCE_ISO_DIR"

    # Check if already mounted
    if check_mounted; then
        log_warn "ISO 已掛載於: $SOURCE_ISO_DIR"
        return 0
    fi

    # Mount (read-only)
    if ! mount -o loop,ro "$SOURCE_ISO" "$SOURCE_ISO_DIR"; then
        log_error "掛載失敗"
        exit 1
    fi

    log_info "已掛載於: $SOURCE_ISO_DIR"
}

do_copy() {
    log_info "複製 ISO 內容到: $CUSTOM_ISO_DIR"

    # Create target directory
    mkdir -p "$CUSTOM_ISO_DIR"

    # Sync files (preserve permissions, follow symlinks)
    if ! rsync -aHAX "$SOURCE_ISO_DIR/" "$CUSTOM_ISO_DIR/"; then
        log_error "複製失敗"
        exit 1
    fi

    # Count files
    local file_count=$(find "$CUSTOM_ISO_DIR" -type f | wc -l)
    log_info "複製完成，共 $file_count 個檔案"
}

do_unmount() {
    log_info "卸載 ISO..."

    if check_mounted; then
        umount "$SOURCE_ISO_DIR"
        log_info "已卸載: $SOURCE_ISO_DIR"
    else
        log_warn "ISO 未掛載"
    fi

    # Clean up mount point
    if [[ -d "$SOURCE_ISO_DIR" ]]; then
        rm -rf "$SOURCE_ISO_DIR"
        log_info "已清除: $SOURCE_ISO_DIR"
    fi
}

do_clean() {
    log_info "清除 custom-iso 目錄..."
    if [[ -d "$CUSTOM_ISO_DIR" ]]; then
        rm -rf "$CUSTOM_ISO_DIR"
        log_info "已清除: $CUSTOM_ISO_DIR"
    else
        log_warn "custom-iso 目錄不存在"
    fi
}

main() {
    local iso_path=""
    local action="mount+copy"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --iso)
                SOURCE_ISO="$2"
                shift 2
                ;;
            --unmount)
                action="unmount"
                shift
                ;;
            --clean)
                action="clean"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "未知參數: $1"
                usage
                ;;
        esac
    done

    case "$action" in
        mount+copy)
            load_config
            do_mount
            do_copy
            ;;
        unmount)
            do_unmount
            ;;
        clean)
            do_clean
            ;;
    esac
}

main "$@"
