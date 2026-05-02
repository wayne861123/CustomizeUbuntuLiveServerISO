#!/bin/bash
# build_iso.sh - 將 custom-iso 重新封裝為可開機 ISO
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"
CONFIG_FILE="$DATA_DIR/config.conf"
SOURCE_ISO_DIR="$PROJECT_DIR/custom-iso"
STAGING_DIR="$PROJECT_DIR/staging/packages"
OUTPUT_NAME=""

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
  將 custom-iso/ 目錄重新封裝為可開機的 ISO 映像檔。
  會自動偵測來源 ISO 的架構與開機參數，支援 x86_64、arm64 等。

選項:
  --output <name>    輸出 ISO 檔名（預設: customized.iso）
  --no-md5            不重新計算校驗和（加快速度）
  --dry-run           預覽生成的 xorriso 指令
  -h, --help         顯示說明

範例:
  $0 --output my-custom.iso
  $0 --output my-autoinstall.iso --no-md5

EOF
    exit 1
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
}

# ─────────────────────────────────────────
# 從 source ISO 偵測架構（純輸出，不含日誌）
# ─────────────────────────────────────────
detect_architecture() {
    local arch="unknown"
    local efi_path=""
    local has_uefi=0
    local has_bios=0
    local boot_cat_path=""

    # Method 1: 從 EFI 目錄偵測
    if [[ -d "$SOURCE_ISO_DIR/EFI" ]]; then
        if [[ -f "$SOURCE_ISO_DIR/EFI/boot/bootx64.efi" ]]; then
            arch="x86_64"; efi_path="EFI/boot/bootx64.efi"; has_uefi=1
        elif [[ -f "$SOURCE_ISO_DIR/EFI/boot/bootaa64.efi" ]]; then
            arch="arm64"; efi_path="EFI/boot/bootaa64.efi"; has_uefi=1
        elif [[ -f "$SOURCE_ISO_DIR/EFI/boot/bootarm64.efi" ]]; then
            arch="arm64"; efi_path="EFI/boot/bootarm64.efi"; has_uefi=1
        fi
    fi

    # Method 2: 從 boot/grub 目錄偵測
    if [[ -d "$SOURCE_ISO_DIR/boot/grub" ]]; then
        if [[ -f "$SOURCE_ISO_DIR/boot/grub/i386-pc/eltorito.img" ]]; then
            has_bios=1
        fi
        if [[ -d "$SOURCE_ISO_DIR/boot/grub/x86_64-efi" ]]; then
            arch="${arch:-x86_64}"; has_uefi=1
        elif [[ -d "$SOURCE_ISO_DIR/boot/grub/arm64-efi" ]]; then
            arch="arm64"; has_uefi=1
            efi_path="${efi_path:-EFI/boot/bootaa64.efi}"
        fi
    fi

    # Method 3: 嘗試從 xorriso 讀取（需要原始 ISO）
    if [[ -f "$SOURCE_ISO" ]] && command -v xorriso &> /dev/null; then
        local iso_info
        iso_info=$(xorriso -indev "$SOURCE_ISO" -report_el_torito as_mkisofs 2>/dev/null || echo "")
        if echo "$iso_info" | grep -qi "x86_64"; then
            arch="x86_64"; has_uefi=1; efi_path="${efi_path:-EFI/boot/bootx64.efi}"
        elif echo "$iso_info" | grep -qi "AA64\|aarch64"; then
            arch="arm64"; has_uefi=1; efi_path="${efi_path:-EFI/boot/bootaa64.efi}"
        fi
        if echo "$iso_info" | grep -qi "BIOS\|i386"; then
            has_bios=1
        fi
    fi

    # Fallback
    if [[ "$arch" == "unknown" ]]; then
        arch="x86_64"; has_uefi=1; has_bios=1
        efi_path="${efi_path:-EFI/boot/bootx64.efi}"
    fi

    # 輸出格式：5個空格分隔的值
    printf '%s %s %s %s %s' "$arch" "$has_uefi" "$has_bios" "$efi_path" "$boot_cat_path"
}

# ─────────────────────────────────────────
# 偵測 Volume ID
# ─────────────────────────────────────────
detect_volume_id() {
    local volid="CustomUbuntu"
    if [[ -f "$SOURCE_ISO_DIR/.disk/info" ]]; then
        volid=$(cat "$SOURCE_ISO_DIR/.disk/info" 2>/dev/null | head -1 | tr -d '\n')
    fi
    echo "${volid:0:32}"
}

# ─────────────────────────────────────────
# 更新 filesystem.size
# ─────────────────────────────────────────
update_filesystem_size() {
    local squashfs="$SOURCE_ISO_DIR/casper/ubuntu-server-minimal.squashfs"
    if [[ -f "$squashfs" ]]; then
        local size
        size=$(du -sb "$squashfs" 2>/dev/null | cut -f1)
        echo "$size" > "$SOURCE_ISO_DIR/casper/filesystem.size"
        log_info "更新 filesystem.size: $size bytes"
    fi
}

# ─────────────────────────────────────────
# 重新計算校驗和
# ─────────────────────────────────────────
update_checksums() {
    log_info "重新計算 SHA256SUMS..."
    local sha_file="$SOURCE_ISO_DIR/casper/SHA256SUMS"
    if [[ -d "$SOURCE_ISO_DIR/casper" ]]; then
        (cd "$SOURCE_ISO_DIR/casper" && \
            find . -type f ! -name "*.sha256sum" ! -name "SHA256SUMS*" | \
            sort | xargs sha256sum 2>/dev/null) > "$sha_file.tmp" || true
        mv "$sha_file.tmp" "$sha_file"
    fi
}

# ─────────────────────────────────────────
# 生成 xorriso 參數（純函式，回傳 params）
# ─────────────────────────────────────────
build_xorriso_params() {
    local arch="$1"
    local has_uefi="$2"
    local has_bios="$3"
    local efi_path="$4"
    local volid="$5"
    local output_iso="$6"

    local -a params=(
        "-report_aboutitori" "WARNING"
        "-outdev" "$output_iso"
        "-map" "$SOURCE_ISO_DIR/" "/"
    )

    # BIOS boot
    if [[ "$has_bios" == "1" ]]; then
        local eltorito_img=""
        if [[ -f "$SOURCE_ISO_DIR/boot/grub/i386-pc/eltorito.img" ]]; then
            eltorito_img="boot/grub/i386-pc/eltorito.img"
        elif [[ -f "$SOURCE_ISO_DIR/boot/isolinux/isolinux.bin" ]]; then
            eltorito_img="boot/isolinux/isolinux.bin"
        fi
        if [[ -n "$eltorito_img" ]]; then
            params+=(
                "-boot_image" "any" "partition_table=on"
                "-boot_image" "any" "partition_cyl_align=off"
                "-boot_image" "any" "eltorito=$eltorito_img"
            )
        fi
    fi

    # UEFI boot
    if [[ "$has_uefi" == "1" ]] && [[ -n "$efi_path" ]] && [[ -f "$SOURCE_ISO_DIR/$efi_path" ]]; then
        params+=(
            "-boot_image" "any" "efi_path=$efi_path"
            "-boot_image" "grub2" "uefi_start=on"
            "-boot_image" "any" "uefi=on"
        )
    fi

    # General
    params+=(
        "-boot_image" "any" "iso_nowipe=on"
        "-boot_image" "any" "，盘上 hfsplus=off"
        "-boot_image" "any" "，盘上 system_area="
        "-boot_image" "grub2" "bootloader_id=Ubuntu"
        "-boot_image" "any" "arch=$arch"
        "-volid" "$volid"
    )

    printf '%s\n' "${params[@]}"
}

# ─────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────
main() {
    local skip_checksums=0
    local dry_run=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --output)
                OUTPUT_NAME="$2"; shift 2 ;;
            --no-md5|--no-sha256)
                skip_checksums=1; shift ;;
            --dry-run)
                dry_run=1; shift ;;
            -h|--help) usage ;;
            *) log_error "未知參數: $1"; usage ;;
        esac
    done

    load_config

    if [[ ! -d "$SOURCE_ISO_DIR" ]]; then
        log_error "custom-iso/ 目錄不存在，請先執行 prepare_iso.sh"
        exit 1
    fi

    # 預設輸出名稱
    if [[ -z "$OUTPUT_NAME" ]]; then
        OUTPUT_NAME="${OUTPUT_NAME:-customized.iso}"
    fi
    if [[ "$OUTPUT_NAME" != /* ]]; then
        OUTPUT_NAME="$PROJECT_DIR_VAL/$OUTPUT_NAME"
    fi

    # 偵測架構
    local arch has_uefi has_bios efi_path boot_cat_path
    read -r arch has_uefi has_bios efi_path boot_cat_path <<< "$(detect_architecture)"

    log_info "偵測到架構: $arch (UEFI=$has_uefi, BIOS=$has_bios)"
    log_info "EFI 路徑: $efi_path"

    # 偵測 Volume ID
    local volid
    volid=$(detect_volume_id)
    log_info "Volume ID: $volid"

    echo ""
    echo "========================================"
    echo -e "${BOLD}ISO 建構資訊${NC}"
    echo "========================================"
    echo "  架構:     $arch"
    echo "  UEFI:     $([[ $has_uefi == 1 ]] && echo 是 || echo 否)"
    echo "  BIOS:     $([[ $has_bios == 1 ]] && echo 是 || echo 否)"
    echo "  EFI 路徑: ${efi_path:-無}"
    echo "  Volume:   $volid"
    echo "  輸出:     $OUTPUT_NAME"
    echo "========================================"
    echo ""

    # 更新 metadata
    update_filesystem_size
    if [[ "$skip_checksums" == "0" ]]; then
        update_checksums
    else
        log_info "跳過校驗和計算（--no-md5）"
    fi

    mkdir -p "$(dirname "$OUTPUT_NAME")"

    log_info "正在封裝 ISO..."

    # 建構 xorriso 參數
    local -a xorriso_args
    while IFS= read -r line; do
        xorriso_args+=("$line")
    done < <(build_xorriso_params "$arch" "$has_uefi" "$has_bios" "$efi_path" "$volid" "$OUTPUT_NAME")

    if [[ "$dry_run" == "1" ]]; then
        echo -e "${CYAN}xorriso 指令:${NC}"
        echo "xorriso \\"
        for arg in "${xorriso_args[@]}"; do
            echo "  $(printf '%q' "$arg") \\"
        done
        echo ""
        return 0
    fi

    if ! xorriso "${xorriso_args[@]}" 2>&1; then
        log_error "ISO 封裝失敗"
        exit 1
    fi

    local size
    size=$(du -h "$OUTPUT_NAME" | cut -f1)
    log_info "ISO 建構完成！"
    echo ""
    echo "  輸出: $OUTPUT_NAME"
    echo "  大小: $size"
    echo ""
}

main "$@"
