#!/bin/bash
# build.sh - 自動化建構流程，串接所有步驟
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"
CONFIG_FILE="$DATA_DIR/config.conf"

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

# ─────────────────────────────────────────
# 載入設定
# ─────────────────────────────────────────
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi

    if [[ -z "$SOURCE_ISO" ]]; then
        log_error "尚未設定 SOURCE_ISO，請先執行 init.sh 或手動設定 data/config.conf"
        exit 1
    fi

    if [[ ! -f "$SOURCE_ISO" ]]; then
        log_error "ISO 檔案不存在: $SOURCE_ISO"
        exit 1
    fi
}

# ─────────────────────────────────────────
# Step 1: 初始化（選項）
# ─────────────────────────────────────────
step_init() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}Step 1: 初始化設定${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "設定檔已存在: $CONFIG_FILE"
        source "$CONFIG_FILE"
        echo "  SOURCE_ISO: $SOURCE_ISO"
        echo "  PROJECT_DIR: $PROJECT_DIR_VAL"
        echo ""

        read -p "跳過初始化，直接使用現有設定？(Y/n): " skip
        if [[ ! "$skip" =~ ^[Nn]$ ]]; then
            return 0
        fi
    fi

    log_info "執行 init.sh..."
    bash "$SCRIPT_DIR/init.sh"
}

# ─────────────────────────────────────────
# Step 2: 提取 ISO
# ─────────────────────────────────────────
step_prepare_iso() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}Step 2: 提取 ISO 到 custom-iso/${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    if [[ -d "$PROJECT_DIR/custom-iso/casper" ]]; then
        log_info "custom-iso/ 已存在，略過提取"
        return 0
    fi

    log_info "執行 prepare_iso.sh..."
    bash "$SCRIPT_DIR/prepare_iso.sh"
    log_info "完成"
}

# ─────────────────────────────────────────
# Step 3: 設定 autoinstall（選項）
# ─────────────────────────────────────────
step_autoinstall() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}Step 3: 設定 Autoinstall（選項）${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    if [[ -f "$PROJECT_DIR/custom-iso/user-data" ]]; then
        log_info "user-data 已存在，略過"
        return 0
    fi

    echo "是否要設定 autoinstall？（无人值守安装）"
    echo "  如果不需要自動安裝，可以跳過"
    echo ""
    echo -e "  ${CYAN}1.${NC} 互動式編輯 user-data"
    echo -e "  ${CYAN}2.${NC} 使用現有檔案（data/autoinstall/user-data）"
    echo -e "  ${CYAN}3.${NC} 跳過（不安裝 autoinstall）"
    echo ""
    read -p "請選擇 (1/2/3): " choice

    case "$choice" in
        1)
            bash "$SCRIPT_DIR/autoinstall.sh" --interactive
            ;;
        2)
            local userdata="$DATA_DIR/autoinstall/user-data"
            if [[ -f "$userdata" ]]; then
                bash "$SCRIPT_DIR/autoinstall.sh" --file "$userdata"
            else
                log_warn "找不到 $userdata，請先產生範本或使用 --interactive"
            fi
            ;;
        *)
            log_info "跳過 autoinstall 設定"
            ;;
    esac
}

# ─────────────────────────────────────────
# Step 4: Unsquash（注入用）
# ─────────────────────────────────────────
step_unsquash() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}Step 4: 解壓 squashfs 到 squashfs-root/${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    if [[ -d "$PROJECT_DIR/squashfs-root" ]]; then
        log_info "squashfs-root/ 已存在"
        read -p "要重新解壓嗎？會覆蓋現有內容 (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            bash "$SCRIPT_DIR/inject.sh" --clean
        else
            return 0
        fi
    fi

    log_info "執行 inject.sh --unsquash..."
    bash "$SCRIPT_DIR/inject.sh" --unsquash

    echo ""
    log_info "squashfs-root/ 已建立"
    echo "你可以將想要保留的檔案放入此目錄"
    echo ""
    read -p "完成注入後，按 Enter 繼續重新封裝（或輸入 'skip' 跳過封裝）：" input

    if [[ "$input" != "skip" ]]; then
        log_info "執行 inject.sh --resquash..."
        bash "$SCRIPT_DIR/inject.sh" --resquash
    fi
}

# ─────────────────────────────────────────
# Step 5: 下載 packages（選項）
# ─────────────────────────────────────────
step_packages() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}Step 5: 下載額外套件（選項）${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    if [[ -d "$PROJECT_DIR/staging/packages" ]] && [[ -n "$(ls -A "$PROJECT_DIR/staging/packages" 2>/dev/null)" ]]; then
        log_info "staging/packages/ 已有內容"
        ls "$PROJECT_DIR/staging/packages/" | wc -l | xargs echo "  已下載套件數："
    fi

    echo ""
    echo "是否要下載額外的套件？"
    echo -e "  ${CYAN}1.${NC} 新增 repo 並下載套件"
    echo -e "  ${CYAN}2.${NC} 跳過（繼續建構 ISO）"
    echo ""
    read -p "請選擇 (1/2): " choice

    if [[ "$choice" == "1" ]]; then
        bash "$SCRIPT_DIR/menu.sh"
    else
        log_info "跳過 package 下載"
    fi
}

# ─────────────────────────────────────────
# Step 6: 建構 ISO
# ─────────────────────────────────────────
step_build_iso() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}Step 6: 建構最終 ISO${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    load_config

    local output_name="${OUTPUT_NAME:-customized.iso}"
    if [[ "$output_name" != /* ]]; then
        output_name="$PROJECT_DIR_VAL/$output_name"
    fi

    log_info "執行 build_iso.sh..."
    log_info "輸出: $output_name"
    echo ""

    bash "$SCRIPT_DIR/build_iso.sh" --output "$output_name"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  建構完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    ls -lh "$output_name"
    echo ""
    log_info "ISO 已完成，可以燒錄或測試了"
}

# ─────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────
usage() {
    cat << EOF
用法: $0 [選項]

說明:
  自動化建構流程，串接所有步驟。一次執行完成。
  會依序執行：初始化 → 提取 ISO → 設定 autoinstall →
             解壓 squashfs →（可選）下載 packages → 建構 ISO

  也可以單獨執行特定步驟。

選項:
  --init          僅執行 Step 1（初始化）
  --prepare       僅執行 Step 2（提取 ISO）
  --autoinstall   僅執行 Step 3（設定 autoinstall）
  --unsquash      僅執行 Step 4（解壓 squashfs）
  --packages      僅執行 Step 5（下載套件）
  --build         僅執行 Step 6（建構 ISO）
  --all           執行全部流程（預設）
  --dry-run       預覽要執行的步驟
  -h, --help      顯示說明

範例:
  $0 --all        # 執行全部流程
  $0 --prepare    # 只提取 ISO
  $0 --build      # 只建構 ISO（假設前面已完成）

EOF
    exit 1
}

main() {
    local run_step_init=0
    local run_step_prepare=0
    local run_step_autoinstall=0
    local run_step_unsquash=0
    local run_step_packages=0
    local run_step_build=0
    local dry_run=0

    if [[ $# -eq 0 ]]; then
        # 預設執行全部
        run_step_init=1
        run_step_prepare=1
        run_step_autoinstall=1
        run_step_unsquash=1
        run_step_packages=1
        run_step_build=1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --init)        run_step_init=1 ;;
            --prepare)     run_step_prepare=1 ;;
            --autoinstall) run_step_autoinstall=1 ;;
            --unsquash)    run_step_unsquash=1 ;;
            --packages)    run_step_packages=1 ;;
            --build)       run_step_build=1 ;;
            --all)
                run_step_init=1
                run_step_prepare=1
                run_step_autoinstall=1
                run_step_unsquash=1
                run_step_packages=1
                run_step_build=1
                ;;
            --dry-run)
                dry_run=1
                echo "預覽即將執行的步驟："
                [[ $run_step_init -eq 1 ]] && echo "  [1] 初始化設定"
                [[ $run_step_prepare -eq 1 ]] && echo "  [2] 提取 ISO"
                [[ $run_step_autoinstall -eq 1 ]] && echo "  [3] 設定 Autoinstall"
                [[ $run_step_unsquash -eq 1 ]] && echo "  [4] 解壓 squashfs"
                [[ $run_step_packages -eq 1 ]] && echo "  [5] 下載套件"
                [[ $run_step_build -eq 1 ]] && echo "  [6] 建構 ISO"
                exit 0
                ;;
            -h|--help) usage ;;
            *)
                log_error "未知參數: $1"
                usage
                ;;
        esac
        shift
    done

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  CustomizeUbuntuLiveServerISO${NC}"
    echo -e "${CYAN}  自動化建構流程${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    [[ $run_step_init -eq 1 ]] && step_init
    [[ $run_step_prepare -eq 1 ]] && step_prepare_iso
    [[ $run_step_autoinstall -eq 1 ]] && step_autoinstall
    [[ $run_step_unsquash -eq 1 ]] && step_unsquash
    [[ $run_step_packages -eq 1 ]] && step_packages
    [[ $run_step_build -eq 1 ]] && step_build_iso
}

main "$@"