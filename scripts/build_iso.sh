#!/bin/bash
# build_iso.sh - 將 custom-iso 重新封裝為可開機 ISO
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"
CONFIG_FILE="$DATA_DIR/config.conf"
SOURCE_ISO_DIR="$PROJECT_DIR/custom-iso"

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
  將 custom-iso/ 目錄重新封裝為可開機 ISO。
  --output <name>   輸出 ISO 檔名
  --no-md5          跳過校驗和計算
  --dry-run         預覽 xorriso 指令
  -h, --help       顯示說明
EOF
    exit 1
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
}

detect_architecture() {
    local arch="unknown" efi_path="" has_uefi=0 has_bios=0

    [[ -d "$SOURCE_ISO_DIR/EFI" ]] && {
        [[ -f "$SOURCE_ISO_DIR/EFI/boot/bootx64.efi" ]] && { arch="x86_64"; efi_path="EFI/boot/bootx64.efi"; has_uefi=1; }
        [[ -f "$SOURCE_ISO_DIR/EFI/boot/bootaa64.efi" ]] && { arch="arm64";  efi_path="EFI/boot/bootaa64.efi"; has_uefi=1; }
    }

    [[ -d "$SOURCE_ISO_DIR/boot/grub" ]] && {
        [[ -f "$SOURCE_ISO_DIR/boot/grub/i386-pc/eltorito.img" ]] && has_bios=1
        [[ -d "$SOURCE_ISO_DIR/boot/grub/x86_64-efi" ]] && { arch="${arch:-x86_64}"; has_uefi=1; }
        [[ -d "$SOURCE_ISO_DIR/boot/grub/arm64-efi" ]] && { arch="arm64"; has_uefi=1; efi_path="${efi_path:-EFI/boot/bootaa64.efi}"; }
    }

    [[ "$arch" == "unknown" ]] && { arch="x86_64"; has_uefi=1; has_bios=1; efi_path="${efi_path:-EFI/boot/bootx64.efi}"; }

    echo "$arch $has_uefi $has_bios $efi_path"
}

detect_volume_id() {
    local volid="CustomUbuntu"
    if [[ -f "$SOURCE_ISO_DIR/.disk/info" ]]; then
        volid=$(cat "$SOURCE_ISO_DIR/.disk/info" 2>/dev/null | head -1)
        # 移除單引號、雙引號、特殊字元，轉大寫，符合 ISO 9660
        volid=$(echo "$volid" | sed "s/['\"]//g" | xargs echo | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9._-]/_/g')
    fi
    echo "${volid:-CUSTOMUBUNTU}" | cut -c1-32
}

main() {
    local skip_checksums=0 dry_run=0 output_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output) output_name="$2"; shift 2 ;;
            --no-md5|--no-sha256) skip_checksums=1; shift ;;
            --dry-run) dry_run=1; shift ;;
            -h|--help) usage ;;
            *) log_error "未知參數: $1"; usage ;;
        esac
    done

    load_config

    [[ ! -d "$SOURCE_ISO_DIR" ]] && { log_error "custom-iso/ 目錄不存在，請先執行 prepare_iso.sh"; exit 1; }

    [[ -z "$output_name" ]] && output_name="customized.iso"
    [[ "$output_name" != /* ]] && output_name="$PROJECT_DIR_VAL/$output_name"

    local arch has_uefi has_bios efi_path
    read -r arch has_uefi has_bios efi_path <<< "$(detect_architecture)"
    local volid
    volid=$(detect_volume_id)

    log_info "偵測到架構: $arch (UEFI=$has_uefi, BIOS=$has_bios)"
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
    echo "  輸出:     $output_name"
    echo "========================================"
    echo ""

    # Update filesystem.size
    local squashfs="$SOURCE_ISO_DIR/casper/ubuntu-server-minimal.squashfs"
    if [[ -f "$squashfs" ]]; then
        local size=$(du -sb "$squashfs" | cut -f1)
        echo "$size" > "$SOURCE_ISO_DIR/casper/filesystem.size"
        log_info "更新 filesystem.size: $size bytes"
    fi

    if [[ "$skip_checksums" == "0" ]]; then
        log_info "重新計算 SHA256SUMS..."
        local sha_file="$SOURCE_ISO_DIR/casper/SHA256SUMS"
        if [[ -d "$SOURCE_ISO_DIR/casper" ]]; then
            (cd "$SOURCE_ISO_DIR/casper" && find . -type f ! -name "SHA256SUMS*" | sort | xargs sha256sum 2>/dev/null) > "$sha_file.tmp" || true
            mv "$sha_file.tmp" "$sha_file"
        fi
    fi

    mkdir -p "$(dirname "$output_name")"

    # Find eltorito image
    local eltorito_img=""
    if [[ "$has_bios" == "1" ]]; then
        [[ -f "$SOURCE_ISO_DIR/boot/grub/i386-pc/eltorito.img" ]] && eltorito_img="boot/grub/i386-pc/eltorito.img"
        [[ -f "$SOURCE_ISO_DIR/boot/isolinux/isolinux.bin" ]] && eltorito_img="boot/isolinux/isolinux.bin"
    fi

    # Build xorriso command (xorriso 1.5.x)
    local -a xorriso_cmd
    xorriso_cmd[0]="xorriso"
    xorriso_cmd[1]="-outdev"
    xorriso_cmd[2]="$output_name"
    xorriso_cmd[3]="-map"
    xorriso_cmd[4]="$SOURCE_ISO_DIR/"
    xorriso_cmd[5]="/"
    xorriso_cmd[6]="-volid"
    xorriso_cmd[7]="$volid"
    local xc_idx=8

    # BIOS boot
    if [[ -n "$eltorito_img" ]]; then
        xorriso_cmd[$xc_idx]="-boot_image"; ((xc_idx++))
        xorriso_cmd[$xc_idx]="grub2"; ((xc_idx++))
        xorriso_cmd[$xc_idx]="bin_path=$eltorito_img"; ((xc_idx++))
    fi

    # UEFI boot - for ISO images, EFI boot files just need to be in /EFI/boot/
    # No explicit efi_boot_part needed (that's for USB sticks)
    # The mapped /EFI directory provides UEFI boot automatically

    if [[ "$dry_run" == "1" ]]; then
        echo -e "${CYAN}xorriso 指令:${NC}"
        printf '%q ' "${xorriso_cmd[@]}"
        echo ""
        return 0
    fi

    log_info "正在封裝 ISO..."
    "${xorriso_cmd[@]}" || { log_error "ISO 封裝失敗"; exit 1; }

    local size=$(du -h "$output_name" | cut -f1)
    log_info "ISO 建構完成！"
    echo ""
    echo "  輸出: $output_name"
    echo "  大小: $size"
    echo ""
}

main "$@"
