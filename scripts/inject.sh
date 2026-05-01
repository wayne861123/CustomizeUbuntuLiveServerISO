#!/bin/bash
# inject.sh - 解壓縮 casper squashfs 並讓使用者注入檔案
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"
CONFIG_FILE="$DATA_DIR/config.conf"
CUSTOM_ISO_DIR="$PROJECT_DIR/custom-iso"
SQUASH_ROOT="$PROJECT_DIR/squashfs-root"
CASPER_DIR="$CUSTOM_ISO_DIR/casper"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat << EOF
用法: $0 [選項]

說明:
  將 ubuntu-server-minimal.squashfs 解壓縮到 squashfs-root/，
  讓使用者可放入額外檔案（這些檔案在系統安裝後會保留在檔案系統中）。
  注入完成後可選擇重新封裝回 squashfs。

選項:
  --unsquash     解壓縮 squashfs（預設）
  --resquash     重新封裝 squashfs（完成注入後執行）
  --clean        清除 squashfs-root 目錄
  -h, --help     顯示說明

範例:
  $0 --unsquash    # 解壓縮
  $0 --resquash    # 重新封裝
  $0 --clean       # 清除

流程:
  1. ./inject.sh --unsquash   # 解壓縮 squashfs
  2. 將檔案複製到 squashfs-root/ 的任意位置
  3. ./inject.sh --resquash   # 重新封裝

EOF
    exit 1
}

find_squashfs() {
    local squashfs=""

    # Try ubuntu-server-minimal.squashfs first
    if [[ -f "$CASPER_DIR/ubuntu-server-minimal.squashfs" ]]; then
        squashfs="$CASPER_DIR/ubuntu-server-minimal.squashfs"
    elif [[ -f "$CASPER_DIR/filesystem.squashfs" ]]; then
        squashfs="$CASPER_DIR/filesystem.squashfs"
    elif [[ -f "$CASPER_DIR/*.squashfs" ]]; then
        squashfs=$(ls "$CASPER_DIR"/*.squashfs 2>/dev/null | head -1)
    fi

    echo "$squashfs"
}

do_unsquash() {
    local squashfs
    squashfs=$(find_squashfs)

    if [[ -z "$squashfs" ]] || [[ ! -f "$squashfs" ]]; then
        log_error "找不到 squashfs 檔案，請先執行 prepare_iso.sh"
        log_error "預期位置: $CASPER_DIR/*.squashfs"
        exit 1
    fi

    log_info "找到 squashfs: $squashfs"

    # Check if already unsquashed
    if [[ -d "$SQUASH_ROOT" ]]; then
        log_warn "squashfs-root/ 已存在"
        read -p "是否要覆寫？(y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "已取消"
            return
        fi
        rm -rf "$SQUASH_ROOT"
    fi

    log_info "解壓縮中（請稍候）..."

    if ! unsquashfs -d "$SQUASH_ROOT" "$squashfs" 2>&1 | tail -5; then
        log_error "解壓縮失敗"
        exit 1
    fi

    local file_count=$(find "$SQUASH_ROOT" -type f | wc -l)
    log_info "解壓縮完成！"
    echo ""
    echo "========================================"
    echo -e "${BOLD}注入說明${NC}"
    echo "========================================"
    echo "squashfs-root/ 已建立"
    echo ""
    echo "將你想要在安裝後系統中保留的檔案放入此目錄："
    echo ""
    echo "  $SQUASH_ROOT"
    echo ""
    echo "常見用途："
    echo "  - 預設的使用者檔案 (~/.bashrc, ~/.profile 等)"
    echo "  - 設定檔 (/etc/skel/ 下的內容會複製到新使用者家目錄)"
    echo "  - 額外安裝的軟體（需配合 preseed 或 autoinstall）"
    echo "  - systemd service/unit 檔案"
    echo ""
    echo "完成注入後，執行："
    echo -e "  ${CYAN}./inject.sh --resquash${NC}"
    echo "========================================"
}

do_resquash() {
    local squashfs
    squashfs=$(find_squashfs)

    if [[ -z "$squashfs" ]] || [[ ! -f "$squashfs" ]]; then
        log_error "找不到原始 squashfs: $squashfs"
        exit 1
    fi

    if [[ ! -d "$SQUASH_ROOT" ]]; then
        log_error "squashfs-root/ 不存在，請先執行 --unsquash"
        exit 1
    fi

    echo ""
    echo -e "${BOLD}即將重新封裝 squashfs${NC}"
    echo ""
    echo "此操作會置換原有 squashfs 檔案"
    echo ""
    read -p "確認繼續？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "已取消"
        return
    fi

    log_info "重新封裝中（請稍候）..."

    # Backup original
    cp "$squashfs" "${squashfs}.bak"
    log_info "原始檔案已備份: ${squashfs}.bak"

    # Resquash
    if ! mksquashfs "$SQUASH_ROOT" "$squashfs" -comp xz -no-duplicates 2>&1 | tail -5; then
        log_error "封裝失敗，嘗試恢復備份..."
        mv "${squashfs}.bak" "$squashfs"
        exit 1
    fi

    local size=$(du -h "$squashfs" | cut -f1)
    log_info "封裝完成！"
    echo "  輸出: $squashfs"
    echo "  大小: $size"
    echo ""
    log_info "可刪除備份: rm ${squashfs}.bak"
}

do_clean() {
    if [[ -d "$SQUASH_ROOT" ]]; then
        rm -rf "$SQUASH_ROOT"
        log_info "已清除: $SQUASH_ROOT"
    else
        log_warn "squashfs-root/ 不存在"
    fi

    # Remove backups
    if [[ -d "$CASPER_DIR" ]]; then
        rm -f "$CASPER_DIR"/*.bak
        log_info "已清除備份檔案"
    fi
}

# ─────────────────────────────────────────
# Main
# ─────────────────────────────────────────
ACTION="unsquash"

while [[ $# -gt 0 ]]; do
    case $1 in
        --unsquash)
            ACTION="unsquash"
            shift
            ;;
        --resquash)
            ACTION="resquash"
            shift
            ;;
        --clean)
            ACTION="clean"
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

case "$ACTION" in
    unsquash)  do_unsquash ;;
    resquash)  do_resquash ;;
    clean)     do_clean ;;
esac
