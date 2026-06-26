#!/bin/bash
set -e

# ============================================================
# Vulkan 软件驱动安装脚本 - 注入 SwiftShader 到 WSA 镜像
# ============================================================
# 使用方法:
#   自动:    ./install_vulkan.sh <artifact_folder>
#   手动:    ./install_vulkan.sh --binary <path_to_libvk_swiftshader.so> <artifact_folder>
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(pwd)"
MOUNT_BASE="$WORK_DIR/mount_temp"
WSA_PATH="$WORK_DIR/output/$1"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[VULKAN]${NC} $1"; }
warn()  { echo -e "${YELLOW}[VULKAN]${NC} $1"; }
error() { echo -e "${RED}[VULKAN]${NC} $1"; }

abort() {
    echo "Error: $1"
    exit 1
}

# 检查 WSA 镜像
check_wsa_images() {
    if [ -z "$1" ]; then
        error "用法: $0 <artifact_folder>"
        error "  或: $0 --binary <so_path> <artifact_folder>"
        exit 1
    fi
    if [ ! -f "$WSA_PATH/vendor.img" ] && [ ! -f "$WSA_PATH/vendor.vhdx" ]; then
        error "在 $WSA_PATH 中找不到 vendor.img 或 vendor.vhdx"
        error "请先运行 build.sh 或确认路径正确"
        exit 1
    fi
}

# 挂载 vendor 镜像
mount_vendor() {
    local vendor_img="$WSA_PATH/vendor.img"
    local vendor_vhdx="$WSA_PATH/vendor.vhdx"
    
    # 如果只有 vhdx，先转 img
    if [ ! -f "$vendor_img" ] && [ -f "$vendor_vhdx" ]; then
        info "转换 vendor.vhdx 为 raw 格式..."
        qemu-img convert -f vhdx -O raw "$vendor_vhdx" "$vendor_img"
    fi
    
    mkdir -p "$MOUNT_BASE/vendor"
    info "挂载 vendor 镜像到 $MOUNT_BASE/vendor"
    sudo mount -o loop "$vendor_img" "$MOUNT_BASE/vendor"
    
    # 探测正确的 vendor 根路径
    if [ -d "$MOUNT_BASE/vendor/vendor" ]; then
        VENDOR_MNT="$MOUNT_BASE/vendor/vendor"
    elif [ -d "$MOUNT_BASE/vendor/lib" ] || [ -d "$MOUNT_BASE/vendor/etc" ]; then
        VENDOR_MNT="$MOUNT_BASE/vendor"
    else
        error "无法识别 vendor 镜像结构"
        ls -la "$MOUNT_BASE/vendor/"
        exit 1
    fi
    info "Vendor 根路径: $VENDOR_MNT"
}

# 查找 SwiftShader 二进制
find_swiftshader() {
    local custom_path="$1"
    
    if [ -n "$custom_path" ] && [ -f "$custom_path" ]; then
        SWIFTSHADER_SO="$custom_path"
        info "使用自定义 SwiftShader: $SWIFTSHADER_SO"
        return 0
    fi
    
    # 查找默认位置
    local default_path="$SCRIPT_DIR/output/libvk_swiftshader.so"
    if [ -f "$default_path" ]; then
        SWIFTSHADER_SO="$default_path"
        info "使用本地构建的 SwiftShader: $SWIFTSHADER_SO"
        return 0
    fi
    
    # 尝试自动构建
    warn "未找到 libvk_swiftshader.so"
    warn "尝试自动构建 SwiftShader..."
    if bash "$SCRIPT_DIR/build_swiftshader.sh"; then
        if [ -f "$default_path" ]; then
            SWIFTSHADER_SO="$default_path"
            info "SwiftShader 构建成功: $SWIFTSHADER_SO"
            return 0
        fi
    fi
    
    # 查找 build 目录中的产物
    local build_so=$(find "$SCRIPT_DIR/build" -name "libvk_swiftshader.so" 2>/dev/null | head -1)
    if [ -f "$build_so" ]; then
        SWIFTSHADER_SO="$build_so"
        info "找到构建产物: $SWIFTSHADER_SO"
        return 0
    fi
    
    error "无法找到 libvk_swiftshader.so"
    error "请先运行: bash $SCRIPT_DIR/build_swiftshader.sh"
    error "或手动提供路径: $0 --binary /path/to/libvk_swiftshader.so <artifact>"
    exit 1
}

# 安装到 vendor 镜像
install_to_vendor() {
    local so_path="$1"
    local so_name=$(basename "$so_path")
    
    info "=== 安装 Vulkan 软件驱动到 vendor 镜像 ==="
    
    # 创建 Vulkan ICD 目录
    sudo mkdir -p "$VENDOR_MNT/lib64/vulkan"
    sudo mkdir -p "$VENDOR_MNT/etc/vulkan/icd.d"
    
    # 复制 SwiftShader 库
    info "复制 $so_name 到 $VENDOR_MNT/lib64/vulkan/"
    sudo cp "$so_path" "$VENDOR_MNT/lib64/vulkan/$so_name"
    
    # 同时复制到 lib64 根目录（ICD JSON 引用的路径）
    info "同时复制到 $VENDOR_MNT/lib64/（兼容 ICD 清单路径）"
    sudo cp "$so_path" "$VENDOR_MNT/lib64/$so_name"
    
    # 复制 ICD 清单
    info "安装 Vulkan ICD 清单..."
    if [ -f "$SCRIPT_DIR/vk_swiftshader_x86_64.json" ]; then
        sudo cp "$SCRIPT_DIR/vk_swiftshader_x86_64.json" "$VENDOR_MNT/etc/vulkan/icd.d/"
        # 同时复制到所有标准位置
        sudo mkdir -p "$VENDOR_MNT/lib64/vulkan/icd.d"
        sudo cp "$SCRIPT_DIR/vk_swiftshader_x86_64.json" "$VENDOR_MNT/lib64/vulkan/icd.d/"
    else
        warn "ICD 清单文件不存在，手动创建..."
        echo '{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "/vendor/lib64/libvk_swiftshader.so",
        "api_version": "1.1"
    }
}' | sudo tee "$VENDOR_MNT/etc/vulkan/icd.d/vk_swiftshader.json" > /dev/null
    fi
    
    # 设置权限
    info "设置文件权限和 SELinux 上下文..."
    sudo chown root:root "$VENDOR_MNT/lib64/vulkan/$so_name"
    sudo chmod 644 "$VENDOR_MNT/lib64/vulkan/$so_name"
    sudo chown root:root "$VENDOR_MNT/lib64/$so_name"
    sudo chmod 644 "$VENDOR_MNT/lib64/$so_name"
    
    # 设置 SELinux 上下文
    if command -v setfattr &>/dev/null; then
        sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" \
            "$VENDOR_MNT/lib64/vulkan/$so_name" 2>/dev/null || true
        sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" \
            "$VENDOR_MNT/lib64/$so_name" 2>/dev/null || true
        sudo find "$VENDOR_MNT/etc/vulkan" -type f -exec setfattr -n security.selinux \
            -v "u:object_r:vendor_configs_file:s0" {} \; 2>/dev/null || true
    fi
    
    info "Vulkan 软件驱动安装完成！"
}

# 验证安装
verify_install() {
    info "=== 验证安装 ==="
    echo ""
    echo "Vulkan 库:"
    ls -lh "$VENDOR_MNT/lib64/vulkan/" 2>/dev/null || echo "  (文件不存在)"
    echo ""
    echo "ICD 清单:"
    ls -lh "$VENDOR_MNT/etc/vulkan/icd.d/" 2>/dev/null || echo "  (文件不存在)"
    echo ""
    
    # 验证库文件完整性
    if [ -f "$VENDOR_MNT/lib64/libvk_swiftshader.so" ]; then
        local so_size=$(stat -c%s "$VENDOR_MNT/lib64/libvk_swiftshader.so" 2>/dev/null || echo 0)
        info "libvk_swiftshader.so 大小: $(numfmt --to=iec $so_size 2>/dev/null || echo ${so_size}B)"
        if [ "$so_size" -lt 1000000 ]; then
            warn "警告: 库文件偏小（< 1MB），可能编译不完整"
        else
            info "库文件大小正常"
        fi
    else
        error "libvk_swiftshader.so 未成功安装！"
        exit 1
    fi
    
    info "验证通过！"
}

# 卸载（清理挂载点）
cleanup() {
    info "清理临时挂载..."
    sudo umount "$MOUNT_BASE/vendor" 2>/dev/null || true
    sudo rm -rf "$MOUNT_BASE" 2>/dev/null || true
}

# 主流程
main() {
    local binary_path=""
    local artifact_folder=""
    
    # 解析参数
    if [ "$1" = "--binary" ]; then
        binary_path="$2"
        artifact_folder="$3"
    else
        artifact_folder="$1"
    fi
    
    echo ""
    echo "================================================"
    echo "  WSA Vulkan 软件驱动安装器"
    echo "  将 SwiftShader 注入 Android 系统镜像"
    echo "================================================"
    echo ""
    
    check_wsa_images "$artifact_folder"
    find_swiftshader "$binary_path"
    mount_vendor
    install_to_vendor "$SWIFTSHADER_SO"
    verify_install
    cleanup
    
    echo ""
    info "================================================"
    info "安装成功！SwiftShader 已注入 WSA 镜像"
    info "Unity URP 应用将检测到 Vulkan 1.1 设备"
    info "所有渲染通过 CPU 完成（软件渲染）"
    info "================================================"
}

# 捕获退出，确保清理
trap cleanup EXIT

main "$@"
