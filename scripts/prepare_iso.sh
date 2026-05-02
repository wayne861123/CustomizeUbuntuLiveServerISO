#!/bin/bash
# prepare_iso.sh - 用 bsdtar 解壓縮 ISO 內容到 custom-iso 目錄
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"
CONFIG_FILE="$DATA_DIR/config.conf"

# Directories
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
  使用 bsdtar 解壓縮 ISO 內容到 custom-iso 目錄。
  會讀取 data/config.conf 中的 SOURCE_ISO 設定。

  輸出目錄: custom-iso/

選項:
  --iso <path>    直接指定 ISO 路徑（忽略 config）
  --re-extract    強制重新解壓（覆寫 custom-iso）
  --clean         清除 custom-iso 目錄
  -h, --help      顯示說明

範例:
  $0                    # 解壓縮 ISO（首次）
  $0 --iso /path/to.iso # 指定 ISO 路徑
  $0 --re-extract       # 重新解壓（覆寫）

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

    # Check bsdtar exists
    if ! command -v bsdtar &> /dev/null; then
        log_error "缺少 bsdtar，請安裝: sudo apt install libarchive-tools"
        exit 1
    fi
}

do_extract() {
    local force="$1"

    # Check if already extracted
    if [[ -d "$CUSTOM_ISO_DIR/casper" ]] && [[ "$force" != "1" ]]; then
        log_warn "custom-iso/ 已存在"
        log_info "使用 --re-extract 強制重新解壓"
        return 0
    fi

    if [[ "$force" == "1" ]]; then
        log_info "強制重新解壓..."
        rm -rf "$CUSTOM_ISO_DIR"
    fi

    log_info "解壓 ISO: $SOURCE_ISO"
    log_info "目的地: $CUSTOM_ISO_DIR"

    mkdir -p "$CUSTOM_ISO_DIR"

    # Use bsdtar to extract ISO content
    if ! bsdtar -xf "$SOURCE_ISO" -C "$CUSTOM_ISO_DIR" 2>&1; then
        log_error "解壓失敗"
        rm -rf "$CUSTOM_ISO_DIR"
        exit 1
    fi

    local file_count=$(find "$CUSTOM_ISO_DIR" -type f 2>/dev/null | wc -l)
    log_info "解壓完成，共 $file_count 個檔案"

    # Count casper size
    if [[ -f "$CUSTOM_ISO_DIR/casper/ubuntu-server-minimal.squashfs" ]]; then
        local squashfs_size=$(du -h "$CUSTOM_ISO_DIR/casper/ubuntu-server-minimal.squashfs" | cut -f1)
        log_info "主要系統映像: ubuntu-server-minimal.squashfs ($squashfs_size)"
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
    local re_extract=0
    local do_clean_flag=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --iso)
                SOURCE_ISO="$2"
                shift 2
                ;;
            --re-extract)
                re_extract=1
                shift
                ;;
            --clean)
                do_clean_flag=1
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

    if [[ "$do_clean_flag" == "1" ]]; then
        do_clean
        return
    fi

    load_config
    do_extract "$re_extract"
}

main "$@"
