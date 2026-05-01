#!/bin/bash
# menu.sh - 互動式選單，管理 repo 與 package 安裝
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="$SCRIPT_DIR"
STAGING_DIR="$PROJECT_DIR/staging/packages"
POOL_DIR="$PROJECT_DIR/custom-iso/pool/main/extra"
DATA_DIR="$PROJECT_DIR/data"
CONFIG_FILE="$DATA_DIR/config.conf"
REPOS_DIR="$PROJECT_DIR/repos"
TARGET_FILE="$DATA_DIR/target.conf"

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
# Helper: load config
# ─────────────────────────────────────────
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
    if [[ -f "$TARGET_FILE" ]]; then
        source "$TARGET_FILE"
    fi
    DIST="${DIST:-$(lsb_release -cs 2>/dev/null || grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release)}"
    ARCH="${ARCH:-$(dpkg --print-architecture)}"
}

# ─────────────────────────────────────────
# 1. 新增 repo（互動式）
# ─────────────────────────────────────────
cmd_add_repo() {
    echo ""
    echo -e "${BOLD}新增 APT Repo${NC}"
    echo "請依序輸入以下資訊："
    echo ""

    read -p "Repo 名稱（識別用）: " repo_name
    read -p "Repo URL（不含 dist/component）: " repo_url
    read -p "Distribution (例如 jammy, noble): " repo_dist
    read -p "Component (例如 main, universe): " repo_component

    if [[ -z "$repo_name" ]] || [[ -z "$repo_url" ]] || [[ -z "$repo_dist" ]] || [[ -z "$repo_component" ]]; then
        log_error "所有欄位都必須填寫"
        return
    fi

    # Create repo file
    mkdir -p "$REPOS_DIR"
    cat > "$REPOS_DIR/${repo_name}.list" << EOF
deb [trusted=yes] $repo_url $repo_dist $repo_component
EOF

    log_info "已新增 repo: $repo_name"
    echo "執行 apt-get update..."

    # Update metadata in isolated environment
    build_temp_sources_list

    if APT_CONFIG="$TMP_APT_CONF" apt-get update -qq 2>&1 | tail -3; then
        log_info "Metadata 更新成功"
    else
        log_warn "Metadata 更新失敗，可能 repo URL 有誤"
    fi

    rm -f "$TMP_APT_CONF"
}

# ─────────────────────────────────────────
# Helper: build temporary apt sources.list
# ─────────────────────────────────────────
build_temp_sources_list() {
    mkdir -p "$TMP_DIR/apt"
    TMP_APT_CONF="$TMP_DIR/apt/sources.list"

    cat > "$TMP_APT_CONF" << EOF
deb [arch=$ARCH] http://archive.ubuntu.com/ubuntu/ $DIST main restricted universe multiverse
deb [arch=$ARCH] http://archive.ubuntu.com/ubuntu/ $DIST-updates main restricted universe multiverse
deb [arch=$ARCH] http://archive.ubuntu.com/ubuntu/ $DIST-security main restricted universe multiverse
EOF

    # Append custom repos
    if [[ -d "$REPOS_DIR" ]] && [[ -n "$(ls -A "$REPOS_DIR" 2>/dev/null)" ]]; then
        for rf in "$REPOS_DIR"/*.list; do
            [[ -f "$rf" ]] || continue
            grep -v "^#" "$rf" | grep -v "^$" >> "$TMP_APT_CONF"
        done
    fi
}

# ─────────────────────────────────────────
# Helper: list available packages from repos
# ─────────────────────────────────────────
list_packages() {
    load_config
    TMP_DIR="/tmp/pkg_list_$$"
    mkdir -p "$TMP_DIR/apt"
    build_temp_sources_list

    echo ""
    log_info "更新套件列表（可稍候）..."

    if ! APT_CONFIG="$TMP_APT_CONF" apt-get update -qq 2>&1 | tail -3; then
        log_error "更新失敗，請確認 repo 設定正確"
        rm -rf "$TMP_DIR"
        return
    fi

    echo ""
    echo -e "${BOLD}所有可用套件（按名稱排序）:${NC}"
    echo ""

    APT_CONFIG="$TMP_APT_CONF" apt-cache search . 2>/dev/null | sort | awk '{print $1}' | head -100

    echo ""
    echo "...（共 $(APT_CONFIG="$TMP_APT_CONF" apt-cache search . 2>/dev/null | wc -l) 個套件）"
    echo ""

    rm -rf "$TMP_DIR"
}

# ─────────────────────────────────────────
# 2. 列出全部 package（可選 grep）
# ─────────────────────────────────────────
cmd_list_packages() {
    echo ""
    echo -e "${BOLD}列出所有可用套件${NC}"
    echo ""

    read -p "是否要過濾（grep）套件名稱？(y/N): " do_grep

    if [[ "$do_grep" =~ ^[Yy]$ ]]; then
        read -p "請輸入關鍵字: " pattern
        load_config
        TMP_DIR="/tmp/pkg_grep_$$"
        mkdir -p "$TMP_DIR/apt"
        build_temp_sources_list

        echo ""
        log_info "更新套件列表..."

        if ! APT_CONFIG="$TMP_APT_CONF" apt-get update -qq 2>&1 | tail -2; then
            log_warn "update 失敗，但繼續嘗試搜尋..."
        fi

        echo ""
        echo -e "${BOLD}符合 '${pattern}' 的套件:${NC}"
        echo ""
        APT_CONFIG="$TMP_APT_CONF" apt-cache search "$pattern" 2>/dev/null | sort | awk '{print $1}' | head -50

        rm -rf "$TMP_DIR"
    else
        list_packages
    fi
}

# ─────────────────────────────────────────
# 3. 選擇欲安裝的 package（Plan 模式 + 背景下載）
# ─────────────────────────────────────────
cmd_select_packages() {
    echo ""
    echo -e "${BOLD}選擇欲安裝的套件${NC}"
    echo "輸入套件名稱（多個用空白分隔），輸入完成後按空白行跳至下一步"
    echo "（可用 , 或 空白 分隔）"
    echo ""

    local selected=()
    while true; do
        read -p "新增套件（直接Enter跳過）: " input
        if [[ -z "$input" ]]; then
            break
        fi

        # Split by comma or space
        IFS=', ' read -ra parts <<< "$input"
        for pkg in "${parts[@]}"; do
            [[ -n "$pkg" ]] && selected+=("$pkg")
        done
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
        log_warn "未選擇任何套件"
        return
    fi

    # ── Plan 模式 ──
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Plan: 即將下載的套件（含依賴）${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""
    echo "直接指定的套件:"
    for pkg in "${selected[@]}"; do
        echo "  + $pkg"
    done
    echo ""

    echo "依賴解析中（可稍候）..."
    echo ""

    load_config
    TMP_DIR="/tmp/pkg_plan_$$"
    mkdir -p "$TMP_DIR/apt"
    build_temp_sources_list

    # Update
    APT_CONFIG="$TMP_APT_CONF" apt-get update -qq 2>&1 | tail -2 || true

    # Show dependencies for each package
    for pkg in "${selected[@]}"; do
        echo -e "${BOLD}  $pkg 的依賴:${NC}"
        APT_CONFIG="$TMP_APT_CONF" apt-cache depends "$pkg" 2>/dev/null | grep -E "^[ ]*Depends:" | sed 's/^[ ]*Depends: //' | while read -r dep; do
            echo "    - $dep"
        done
        echo ""
    done

    rm -rf "$TMP_DIR"

    echo ""
    read -p "確認下載並安裝到 pool/main/extra？(y/N): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "已取消"
        return
    fi

    # ── 背景下載 ──
    log_info "開始背景下載..."

    # Create pool directory
    mkdir -p "$POOL_DIR"

    # Write package list to a temp file for background job
    local download_list="$DATA_DIR/.download_queue.txt"
    printf '%s\n' "${selected[@]}" > "$download_list"

    # Start download in background
    (
        exec > "$DATA_DIR/.download_log.txt" 2>&1
        bash "$SCRIPTS_DIR/pkg.sh" download $(cat "$download_list")
        # Move downloaded debs to pool
        if [[ -d "$STAGING_DIR" ]]; then
            cp -v "$STAGING_DIR"/*.deb "$POOL_DIR/" 2>/dev/null || true
        fi
        rm -f "$download_list"
        echo "DONE" >> "$DATA_DIR/.download_done.txt"
    ) &

    local bg_pid=$!
    echo "$bg_pid" > "$DATA_DIR/.download_pid.txt"

    log_info "下載已啟動（PID: $bg_pid）"
    echo "完成後會寫入 $DATA_DIR/.download_done.txt"
    echo ""
    echo "可用以下指令查看進度："
    echo "  tail -f $DATA_DIR/.download_log.txt"
    echo ""
    echo "返回主選單..."
}

# ─────────────────────────────────────────
# 3. 查看下載狀態
# ─────────────────────────────────────────
cmd_download_status() {
    local pid_file="$DATA_DIR/.download_pid.txt"
    local done_file="$DATA_DIR/.download_done.txt"
    local log_file="$DATA_DIR/.download_log.txt"

    if [[ -f "$done_file" ]]; then
        echo ""
        log_info "下載已完成！"
        echo ""
        local count=$(find "$POOL_DIR" -name "*.deb" 2>/dev/null | wc -l)
        echo "已下載 $count 個 .deb 檔案到: $POOL_DIR"
        rm -f "$pid_file" "$done_file"
        echo ""
        return
    fi

    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo ""
            echo "下載進行中（PID: $pid）"
            echo ""
            echo "最後 10 行輸出："
            tail -10 "$log_file" 2>/dev/null || echo "（尚無輸出）"
        else
            log_warn "下載程序已結束但未正常完成"
        fi
    else
        echo ""
        log_warn "目前沒有正在下載的任務"
    fi
}

# ─────────────────────────────────────────
# 4. 執行下一步（Placeholder）
# ─────────────────────────────────────────
cmd_next_step() {
    echo ""
    echo -e "${BOLD}執行下一步...${NC}"
    echo ""

    # Check if download is done
    if [[ -f "$DATA_DIR/.download_done.txt" ]]; then
        log_info "即將執行 ISO 建構流程..."
        # TODO: call build_iso.sh
        echo "(建構腳本尚未實作)"
    else
        log_warn "還有下載任務尚未完成"
        read -p "仍要繼續？(y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    fi
}

# ─────────────────────────────────────────
# 顯示主選單
# ─────────────────────────────────────────
show_menu() {
    load_config

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  CustomizeUbuntuLiveServerISO 選單${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo -e "  ${BOLD}目標平台:${NC}  $DIST / $ARCH"
    echo -e "  ${BOLD}專案目錄:${NC}  $PROJECT_DIR"
    echo ""
    echo -e "  ${BOLD}1.${NC} 新增 repo（並更新 metadata）"
    echo -e "  ${BOLD}2.${NC} 列出全部 package"
    echo -e "  ${BOLD}3.${NC} 選擇欲安裝的 package（Plan 模式）"
    echo -e "  ${BOLD}4.${NC} 查看下載狀態"
    echo -e "  ${BOLD}5.${NC} 執行下一步（建構 ISO）"
    echo ""
    echo -e "  ${CYAN}0.${NC} 離開"
    echo ""
}

# ─────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────
main() {
    while true; do
        show_menu
        read -p "請選擇: " choice

        case "$choice" in
            1) cmd_add_repo ;;
            2) cmd_list_packages ;;
            3) cmd_select_packages ;;
            4) cmd_download_status ;;
            5) cmd_next_step ;;
            0) echo ""; log_info "Bye!"; exit 0 ;;
            *) log_error "無效選項，請重新選擇";;
        esac

        echo ""
        read -p "按 Enter 繼續..." enter
    done
}

main "$@"
