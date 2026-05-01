#!/bin/bash
# init.sh - 互動式初始化設定
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"

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

# Config file
CONFIG_FILE="$DATA_DIR/config.conf"

# Default values
DEFAULT_SOURCE_ISO=""
DEFAULT_PROJECT_DIR="$PROJECT_DIR"
DEFAULT_OUTPUT_NAME="customized-ubuntu.iso"
DEFAULT_ISO_LABEL="Custom Ubuntu"
DEFAULT_ISO_DESCRIPTION=""

source_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
}

save_config() {
    mkdir -p "$DATA_DIR"
    cat > "$CONFIG_FILE" << EOF
# CustomizeUbuntuLiveServerISO Config
# Auto-generated

# 來源 ISO 檔案路徑
SOURCE_ISO="$SOURCE_ISO"

# 專案目錄
PROJECT_DIR="$PROJECT_DIR_VAL"

# 輸出 ISO 檔名
OUTPUT_NAME="$OUTPUT_NAME"

# ISO Volume Label (最大 32 字元)
ISO_LABEL="$ISO_LABEL"

# ISO 描述
ISO_DESCRIPTION="$ISO_DESCRIPTION"
EOF
    log_info "設定已儲存: $CONFIG_FILE"
}

find_isos() {
    local search_paths=("$HOME" "/tmp" "/media" "/mnt" "/var/tmp")
    local found=()

    for path in "${search_paths[@]}"; do
        if [[ -d "$path" ]]; then
            while IFS= read -r iso; do
                [[ -f "$iso" ]] && found+=("$iso")
            done < <(find "$path" -maxdepth 3 -name "*.iso" -type f 2>/dev/null)
        fi
    done

    printf '%s\n' "${found[@]}" | sort -u
}

prompt_source_iso() {
    echo ""
    echo -e "${BOLD}選擇來源 ISO${NC}"
    echo "請選擇要使用的 Ubuntu Server ISO 檔案："
    echo ""

    local isos
    mapfile -t isos < <(find_isos)

    if [[ ${#isos[@]} -gt 0 ]]; then
        echo "找到以下 ISO 檔案："
        local i=1
        for iso in "${isos[@]}"; do
            local size=$(du -h "$iso" 2>/dev/null | cut -f1 || echo "?")
            local name=$(basename "$iso")
            echo "  [$i] $name ($size) - $iso"
            ((i++))
        done
        echo ""
        echo -e "${CYAN}[m] 手動輸入路徑${NC}"
        echo ""
    else
        log_warn "找不到任何 .iso 檔案"
        echo ""
    fi

    echo -e "${CYAN}[Enter] 使用之前設定: ${DEFAULT_SOURCE_ISO:-無}${NC}"
    read -p "請選擇或輸入路徑: " choice

    if [[ -z "$choice" ]]; then
        SOURCE_ISO="$DEFAULT_SOURCE_ISO"
    elif [[ "$choice" == "m" ]]; then
        read -p "請輸入 ISO 完整路徑: " SOURCE_ISO
    else
        local idx=$((choice - 1))
        if [[ "$idx" -ge 0 ]] && [[ "$idx" -lt ${#isos[@]} ]]; then
            SOURCE_ISO="${isos[$idx]}"
        else
            log_error "無效選擇"
            exit 1
        fi
    fi

    # Validate
    if [[ -z "$SOURCE_ISO" ]]; then
        log_error "尚未指定來源 ISO"
        exit 1
    fi

    if [[ ! -f "$SOURCE_ISO" ]]; then
        log_error "檔案不存在: $SOURCE_ISO"
        exit 1
    fi

    # Detect ISO info
    echo ""
    log_info "已選擇: $SOURCE_ISO"
    local size=$(du -h "$SOURCE_ISO" | cut -f1)
    echo "  大小: $size"

    # Try to detect Ubuntu version from ISO
    if command -v 7z &> /dev/null; then
        local version=$(7z l "$SOURCE_ISO" 2>/dev/null | grep -oP 'Ubuntu[^"/]+' | head -1 || echo "")
        [[ -n "$version" ]] && echo "  版本: $version"
    fi
}

prompt_project_dir() {
    echo ""
    echo -e "${BOLD}選擇專案目錄${NC}"
    echo "用於存放 staging、repos、logs 等檔案的目錄"
    echo ""
    echo -e "${CYAN}[Enter] 使用預設: ${DEFAULT_PROJECT_DIR}${NC}"
    echo "[m] 手動輸入路徑"
    echo ""
    read -p "請選擇或輸入路徑: " choice

    if [[ -z "$choice" ]]; then
        PROJECT_DIR_VAL="$DEFAULT_PROJECT_DIR"
    elif [[ "$choice" == "m" ]]; then
        read -p "請輸入目錄路徑: " PROJECT_DIR_VAL
    else
        PROJECT_DIR_VAL="$choice"
    fi

    # Create if not exists
    mkdir -p "$PROJECT_DIR_VAL"
    log_info "專案目錄: $PROJECT_DIR_VAL"
}

prompt_output_name() {
    echo ""
    echo -e "${BOLD}設定輸出 ISO 檔名${NC}"
    echo "即將產生的客製化 ISO 檔案名稱"
    echo ""
    echo -e "${CYAN}[Enter] 預設: ${DEFAULT_OUTPUT_NAME}${NC}"
    read -p "請輸入檔名: " choice

    OUTPUT_NAME="${choice:-$DEFAULT_OUTPUT_NAME}"

    # Ensure .iso extension
    if [[ ! "$OUTPUT_NAME" =~ \.iso$ ]]; then
        OUTPUT_NAME="${OUTPUT_NAME}.iso"
    fi

    log_info "輸出檔名: $OUTPUT_NAME"
}

prompt_iso_label() {
    echo ""
    echo -e "${BOLD}設定 ISO Volume Label${NC}"
    echo "ISO 的 Volume Label（最大 32 字元）"
    echo "這會顯示在系統掛載 ISO 時的名稱"
    echo ""
    echo -e "${CYAN}[Enter] 預設: ${DEFAULT_ISO_LABEL}${NC}"
    read -p "請輸入 Label: " choice

    ISO_LABEL="${choice:-$DEFAULT_ISO_LABEL}"

    # Validate length
    if [[ ${#ISO_LABEL} -gt 32 ]]; then
        log_warn "Label 超過 32 字元，已截斷"
        ISO_LABEL="${ISO_LABEL:0:32}"
    fi

    log_info "ISO Label: $ISO_LABEL"
}

prompt_iso_description() {
    echo ""
    echo -e "${BOLD}設定 ISO 描述${NC}"
    echo "這個 ISO 的描述或備註（選填）"
    echo ""
    echo -e "${CYAN}[Enter] 預設: ${DEFAULT_ISO_DESCRIPTION:-無}${NC}"
    read -p "請輸入描述: " choice

    ISO_DESCRIPTION="${choice:-$DEFAULT_ISO_DESCRIPTION}"
    log_info "ISO 描述: ${ISO_DESCRIPTION:-無}"
}

show_summary() {
    echo ""
    echo "========================================"
    echo -e "${BOLD}設定摘要${NC}"
    echo "========================================"
    echo "  來源 ISO:    $SOURCE_ISO"
    echo "  專案目錄:    $PROJECT_DIR_VAL"
    echo "  輸出檔名:    $OUTPUT_NAME"
    echo "  ISO Label:   $ISO_LABEL"
    echo "  ISO 描述:    ${ISO_DESCRIPTION:-無}"
    echo "========================================"
    echo ""
}

main() {
    echo ""
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo -e "${BOLD}  CustomizeUbuntuLiveServerISO 初始化${NC}"
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo ""

    # Load existing config if any
    source_config
    DEFAULT_SOURCE_ISO="${SOURCE_ISO:-}"
    DEFAULT_PROJECT_DIR="${PROJECT_DIR_VAL:-$PROJECT_DIR}"
    DEFAULT_OUTPUT_NAME="${OUTPUT_NAME:-customized-ubuntu.iso}"
    DEFAULT_ISO_LABEL="${ISO_LABEL:-Custom Ubuntu}"
    DEFAULT_ISO_DESCRIPTION="${ISO_DESCRIPTION:-}"

    # Interactive prompts
    prompt_source_iso
    prompt_project_dir
    prompt_output_name
    prompt_iso_label
    prompt_iso_description

    # Summary & confirm
    show_summary

    read -p "確認設定？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "已取消"
        exit 0
    fi

    # Save
    save_config

    echo ""
    log_info "初始化完成！"
    echo ""
    echo "接下來可以："
    echo "  1. 用 pkg.sh 新增 repo 並下載 packages"
    echo "  2. 用 pkg.sh set-target 設定目標架構"
    echo "  3. 用 build_iso.sh 開始建構 ISO"
    echo ""
}

main "$@"
