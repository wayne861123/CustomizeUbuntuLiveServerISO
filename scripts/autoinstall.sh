#!/bin/bash
# autoinstall.sh - 設定 Ubuntu Server autoinstall (user-data + meta-data)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CUSTOM_ISO_DIR="$PROJECT_DIR/custom-iso"

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

DEFAULT_USERDATA="$PROJECT_DIR/data/autoinstall/user-data"
DEFAULT_METADATA="$PROJECT_DIR/data/autoinstall/meta-data"

usage() {
    cat << EOF
用法: $0 [選項]

說明:
  將 autoinstall 設定檔（user-data + meta-data）放入 ISO 根目錄。
  這樣開機時會自動執行無人值守安裝。

選項:
  --interactive   互動式編輯 user-data（使用 nano/vim）
  --file <path>   指定現有的 user-data 檔案
  --sample        產生範本 user-data 到 data/autoinstall/
  --show          顯示目前的 user-data 內容
  --remove        移除已設定的 autoinstall 檔案
  -h, --help      顯示說明

範例:
  $0 --sample                # 產生範本
  $0 --interactive           # 互動式編輯
  $0 --file /path/to/user-data
  $0 --show

EOF
    exit 1
}

# 預設 user-data 範本
generate_sample() {
    mkdir -p "$(dirname "$DEFAULT_USERDATA")"
    cat > "$DEFAULT_USERDATA" << 'EOF'
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  network:
    network: disable
  storage:
    layout:
      name: lvm
  identity:
    hostname: ubuntu
    username: ubuntu
    password: "$6$xyz$XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"  # 需加密密碼
  ssh:
    install-server: true
    authorized-keys:
      - ssh-rsa AAAA...  # 你的 SSH 公鑰
  packages:
    - openssh-server
    - vim
    - curl
  late-commands:
    - echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/ubuntu
EOF

    cat > "$DEFAULT_METADATA" << 'EOF'
instance-id: autoinstall
local-hostname: ubuntu
EOF

    log_info "範本已產生："
    echo "  user-data: $DEFAULT_USERDATA"
    echo "  meta-data: $DEFAULT_METADATA"
    echo ""
    echo "請編輯 user-data 範本後，再執行："
    echo -e "  ${CYAN}$0 --file $DEFAULT_USERDATA${NC}"
}

# 檢查 custom-iso 是否存在
check_custom_iso() {
    if [[ ! -d "$CUSTOM_ISO_DIR" ]]; then
        log_error "custom-iso/ 目錄不存在，請先執行 prepare_iso.sh"
        exit 1
    fi
}

# 複製到 ISO 根目錄
install_autoinstall() {
    local userdata="$1"
    local metadata="${2:-$DEFAULT_METADATA}"

    check_custom_iso

    if [[ ! -f "$userdata" ]]; then
        log_error "user-data 檔案不存在: $userdata"
        exit 1
    fi

    # 複製到 ISO 根目錄
    cp "$userdata" "$CUSTOM_ISO_DIR/user-data"
    log_info "已複製 user-data 到 ISO 根目錄"

    # meta-data 如果不存在則建立空白
    if [[ -f "$metadata" ]]; then
        cp "$metadata" "$CUSTOM_ISO_DIR/meta-data"
        log_info "已複製 meta-data 到 ISO 根目錄"
    else
        touch "$CUSTOM_ISO_DIR/meta-data"
        log_info "已建立空白 meta-data"
    fi

    log_info "Autoinstall 設定完成！"
    echo ""
    echo "ISO 根目錄現在包含："
    ls -la "$CUSTOM_ISO_DIR/user-data" "$CUSTOM_ISO_DIR/meta-data" 2>/dev/null
}

# 顯示目前的 user-data
show_current() {
    local userdata="$CUSTOM_ISO_DIR/user-data"
    if [[ -f "$userdata" ]]; then
        echo ""
        echo -e "${BOLD}目前的 user-data:${NC}"
        echo "========================================"
        cat "$userdata"
        echo "========================================"
    else
        echo ""
        log_warn "目前沒有設定 user-data"
        echo "可用 $0 --sample 產生範本"
    fi
}

# 移除 autoinstall 檔案
remove_autoinstall() {
    check_custom_iso
    rm -f "$CUSTOM_ISO_DIR/user-data" "$CUSTOM_ISO_DIR/meta-data"
    log_info "已移除 autoinstall 檔案"
}

# 互動式編輯
interactive_edit() {
    check_custom_iso

    # 如果還沒有範本，先產生
    if [[ ! -f "$DEFAULT_USERDATA" ]]; then
        log_info "產生範本..."
        generate_sample
    fi

    echo ""
    echo "將使用以下檔案進行編輯："
    echo "  $DEFAULT_USERDATA"
    echo ""
    read -p "按 Enter 開始編輯（nano）..."

    nano "$DEFAULT_USERDATA"

    echo ""
    read -p "編輯完成，要安裝到 ISO 嗎？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        install_autoinstall "$DEFAULT_USERDATA"
    fi
}

COMMAND="${1:-}"
shift 2>/dev/null || true

case "$COMMAND" in
    --interactive)
        interactive_edit
        ;;
    --file)
        install_autoinstall "$1"
        ;;
    --sample)
        generate_sample
        ;;
    --show)
        show_current
        ;;
    --remove)
        remove_autoinstall
        ;;
    -h|--help)
        usage
        ;;
    *)
        log_error "未知參數: $COMMAND"
        usage
        ;;
esac
