#!/bin/bash
# pkg.sh - Package downloader with cross-arch/cross-dist support
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STAGING_DIR="$PROJECT_DIR/staging/packages"
DATA_DIR="$PROJECT_DIR/data"
REPOS_DIR="$PROJECT_DIR/repos"
TMP_DIR="/tmp/pkg_work_$$"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Host system info
HOST_ARCH="$(dpkg --print-architecture)"
HOST_DIST="$(lsb_release -cs 2>/dev/null || grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release)"

# Default target = host
DEFAULT_TARGET_FILE="$DATA_DIR/target.conf"

usage() {
    cat << EOF
用法: $0 <指令> [選項]

指令:
  set-target <--dist DIST> [--arch ARCH]
              設定目標 OS 版本與架構
              DIST: jammy(noble), focal, jammy 等
              ARCH: amd64, arm64, i386 (預設: $HOST_ARCH)
              範例: $0 set-target --dist noble --arch arm64

  add-repo <name> <url> <dist> <component>
              新增自訂 apt repo
              範例: $0 add-repo myrepo https://example.com/repo jammy main

  remove-repo <name>
              移除已新增的 repo

  list-repos
              列出所有已新增的 repo

  show-target
              顯示目前目標 OS 與架構

  download <package1> [package2] ...
              下載套件及其依賴到 staging/packages/
              會自動解析所有依賴

  -h, --help
              顯示說明

範例:
  $0 set-target --dist noble --arch arm64
  $0 add-repo myppa https://example.com/repo jammy main
  $0 download nginx curl git

EOF
    exit 1
}

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Ensure directories exist
init_dirs() {
    mkdir -p "$STAGING_DIR" "$DATA_DIR" "$REPOS_DIR"
}

# Read current target
get_target() {
    local dist arch
    if [[ -f "$DEFAULT_TARGET_FILE" ]]; then
        source "$DEFAULT_TARGET_FILE"
        echo "$DIST $ARCH"
    else
        echo "$HOST_DIST $HOST_ARCH"
    fi
}

# Write target config
set_target() {
    local dist="" arch="$HOST_ARCH"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --dist)
                dist="$2"
                shift 2
                ;;
            --arch)
                arch="$2"
                shift 2
                ;;
            *)
                log_error "未知參數: $1"
                usage
                ;;
        esac
    done

    if [[ -z "$dist" ]]; then
        log_error "必須指定 --dist"
        usage
    fi

    init_dirs
    cat > "$DEFAULT_TARGET_FILE" << EOF
# Target OS configuration (auto-generated)
DIST="$dist"
ARCH="$arch"
EOF

    log_info "目標已設定: DIST=$dist, ARCH=$arch"
}

# Show current target
cmd_show_target() {
    local dist arch
    if [[ -f "$DEFAULT_TARGET_FILE" ]]; then
        source "$DEFAULT_TARGET_FILE"
        dist="$DIST"
        arch="$ARCH"
    else
        dist="$HOST_DIST"
        arch="$HOST_ARCH"
    fi

    echo "目標平台:"
    echo "  Distribution: $dist"
    echo "  Architecture: $arch"
    echo "主機平台:"
    echo "  Distribution: $HOST_DIST"
    echo "  Architecture: $HOST_ARCH"
}

# Add a repo
cmd_add_repo() {
    local name="$1" url="$2" dist="$3" component="$4"

    if [[ -z "$name" ]] || [[ -z "$url" ]] || [[ -z "$dist" ]] || [[ -z "$component" ]]; then
        log_error "缺少參數: name url dist component"
        usage
    fi

    init_dirs

    # Validate URL is reachable (just check HTTP headers)
    if ! curl -sI "$url" | grep -q "HTTP"; then
        log_error "無法連線到: $url"
        exit 1
    fi

    cat > "$REPOS_DIR/${name}.list" << EOF
# Repo: $name (auto-generated)
deb [trusted=yes] $url $dist $component
EOF

    log_info "已新增 repo: $name"
}

# Remove a repo
cmd_remove_repo() {
    local name="$1"
    if [[ -z "$name" ]]; then
        log_error "請指定要移除的 repo 名稱"
        usage
    fi

    local file="$REPOS_DIR/${name}.list"
    if [[ -f "$file" ]]; then
        rm "$file"
        log_info "已移除 repo: $name"
    else
        log_error "Repo 不存在: $name"
        exit 1
    fi
}

# List all repos
cmd_list_repos() {
    if [[ ! -d "$REPOS_DIR" ]] || [[ -z "$(ls -A "$REPOS_DIR" 2>/dev/null)" ]]; then
        echo "目前沒有新增任何額外 repo"
        return
    fi

    echo "已新增的 repos:"
    for f in "$REPOS_DIR"/*.list; do
        local name="$(basename "$f" .list)"
        echo "  - $name"
        grep -v "^#" "$f" | grep -v "^$" | sed 's/^/      /'
    done
}

# Build apt sources list for target
build_sources_list() {
    local dist="$1"
    local arch="$2"
    local out="$3"

    cat > "$out" << EOF
# Ubuntu base archive
deb [arch=$arch] http://archive.ubuntu.com/ubuntu/ $dist main restricted universe multiverse
deb [arch=$arch] http://archive.ubuntu.com/ubuntu/ $dist-updates main restricted universe multiverse
deb [arch=$arch] http://archive.ubuntu.com/ubuntu/ $dist-security main restricted universe multiverse
EOF

    # Append custom repos
    if [[ -d "$REPOS_DIR" ]] && [[ -n "$(ls -A "$REPOS_DIR" 2>/dev/null)" ]]; then
        for repo_file in "$REPOS_DIR"/*.list; do
            grep -v "^#" "$repo_file" | grep -v "^$" >> "$out"
        done
    fi
}

# Check if foreign architecture is needed and setup
setup_foreign_arch() {
    local target_arch="$1"

    if [[ "$target_arch" == "$HOST_ARCH" ]]; then
        return 0
    fi

    log_info "偵測到 cross-architecture 需求: host=$HOST_ARCH target=$target_arch"

    # Check if qemu-user-static is installed
    if ! command -v qemu-"$target_arch"-static &> /dev/null && \
       ! command -v qemu-user-static &> /dev/null; then
        log_warn "需要 qemu-user-static 來處理 foreign architecture"
        log_warn "請先安裝: sudo apt install qemu-user-static"
        return 1
    fi

    # Check if already added
    if ! dpkg --print-foreign-architectures 2>/dev/null | grep -q "$target_arch"; then
        log_info "新增 foreign architecture: $target_arch"
        sudo dpkg --add-architecture "$target_arch"
        sudo apt-get update -qq
    fi

    return 0
}

# Download packages with dependencies
cmd_download() {
    local packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        log_error "請指定要下載的套件"
        usage
    fi

    init_dirs

    # Read target
    local dist arch
    if [[ -f "$DEFAULT_TARGET_FILE" ]]; then
        source "$DEFAULT_TARGET_FILE"
        dist="$DIST"
        arch="$ARCH"
    else
        dist="$HOST_DIST"
        arch="$HOST_ARCH"
    fi

    log_info "目標: DIST=$dist, ARCH=$arch"

    # Setup foreign arch if needed
    setup_foreign_arch "$arch" || exit 1

    # Create work directory
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR/apt" "$TMP_DIR/lists" "$TMP_DIR/cache" "$TMP_DIR/debs"
    local apt_sources="$TMP_DIR/apt/sources.list"
    local apt_prefs="$TMP_DIR/apt/preferences"

    # Build sources.list
    build_sources_list "$dist" "$arch" "$apt_sources"

    log_info "更新套件列表..."
    # Update with target sources (isolated environment)
    if ! apt-get update \
        -o Dir::Etc::SourceList="$apt_sources" \
        -o Dir::Etc::SourceParts="-" \
        -o Dir::State::Lists="$TMP_DIR/lists" \
        -o Dir::Cache::Archives="$TMP_DIR/cache" \
        -o APT::Get::List-Cleanup="0" \
        -o Debug::NoLocking=1 \
        2>&1 | tail -5; then
        log_error "apt-get update 失敗"
        exit 1
    fi

    # Create preferences to prefer target arch
    cat > "$apt_prefs" << EOF
Package: *
Pin: release a=$arch
Pin-Priority: 1000
EOF

    log_info "解析依賴並下載: ${packages[*]}"

    # Download packages
    local download_failed=0
    for pkg in "${packages[@]}"; do
        log_info "下載: $pkg"
        if ! apt-get install -y \
            --download-only \
            -o Dir::Etc::SourceList="$apt_sources" \
            -o Dir::Etc::Preferences="$apt_prefs" \
            -o Dir::State::Lists="$TMP_DIR/lists" \
            -o Dir::Cache::Archives="$TMP_DIR/debs" \
            -o DPkg::Options::="--force-depends" \
            -o Debug::NoLocking=1 \
            "$pkg" 2>&1; then
            log_error "下載失敗: $pkg"
            download_failed=1
        fi
    done

    # Copy downloaded debs to staging
    if [[ -d "$TMP_DIR/debs" ]] && [[ -n "$(ls -A "$TMP_DIR/debs" 2>/dev/null)" ]]; then
        cp -v "$TMP_DIR/debs"/*.deb "$STAGING_DIR/" 2>/dev/null || true
        log_info "已下載 $(ls "$TMP_DIR/debs"/*.deb 2>/dev/null | wc -l) 個 .deb 檔案到 staging/"
    fi

    # Cleanup
    rm -rf "$TMP_DIR"

    if [[ "$download_failed" -eq 1 ]]; then
        log_error "部分套件下載失敗"
        exit 1
    fi

    log_info "完成！所有 .deb 檔案位於: $STAGING_DIR"
}

# Parse command
COMMAND="${1:-}"
shift 2>/dev/null || true

case "$COMMAND" in
    set-target)
        set_target "$@"
        ;;
    add-repo)
        cmd_add_repo "$@"
        ;;
    remove-repo)
        cmd_remove_repo "$1"
        ;;
    list-repos)
        cmd_list_repos
        ;;
    show-target)
        cmd_show_target
        ;;
    download)
        cmd_download "$@"
        ;;
    -h|--help)
        usage
        ;;
    *)
        log_error "未知指令: $COMMAND"
        usage
        ;;
esac
