#!/bin/bash
set -e

# ============================================================
# SwiftShader 构建脚本 - 为 Android x86_64 编译软件 Vulkan 驱动
# ============================================================
# SwiftShader 是 Google 开源的纯 CPU Vulkan 实现，
# 可在没有物理 GPU 或 GPU 虚拟化（GPU-PV）失效时提供 Vulkan 支持。
# 许可证: Apache 2.0
# 项目地址: https://swiftshader.googlesource.com/SwiftShader
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR/build"
NDK_DIR=""
SWIFTSHADER_SRC="$WORK_DIR/SwiftShader"
OUTPUT_DIR="$SCRIPT_DIR/output"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查依赖
check_dependencies() {
    local missing=false
    for cmd in git cmake ninja python3; do
        if ! command -v "$cmd" &>/dev/null; then
            error "缺少依赖: $cmd"
            missing=true
        fi
    done
    if [ "$missing" = true ]; then
        error "请先安装缺失的依赖:"
        error "  Ubuntu/Debian: sudo apt install cmake ninja-build python3 git"
        error "  Fedora: sudo dnf install cmake ninja-build python3 git"
        exit 1
    fi
}

# 查找或下载 Android NDK
setup_ndk() {
    # 尝试环境变量
    if [ -n "$ANDROID_NDK_HOME" ] && [ -d "$ANDROID_NDK_HOME" ]; then
        NDK_DIR="$ANDROID_NDK_HOME"
        info "使用环境变量 ANDROID_NDK_HOME: $NDK_DIR"
        return 0
    fi
    if [ -n "$ANDROID_HOME" ] && [ -d "$ANDROID_HOME/ndk" ]; then
        NDK_DIR=$(ls -d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)
        if [ -n "$NDK_DIR" ] && [ -d "$NDK_DIR" ]; then
            info "使用 Android SDK NDK: $NDK_DIR"
            return 0
        fi
    fi
    # 尝试已知路径
    for path in /usr/local/lib/android/sdk/ndk/* /opt/android-ndk* "$HOME/Android/Sdk/ndk/*"; do
        for p in $path; do
            if [ -d "$p" ] && [ -f "$p/build/cmake/android.toolchain.cmake" ]; then
                NDK_DIR="$p"
                info "找到 NDK: $NDK_DIR"
                return 0
            fi
        done
    done
    # 自动下载 NDK
    warn "未找到 Android NDK，开始下载 NDK r27..."
    mkdir -p "$WORK_DIR"
    local ndk_zip="$WORK_DIR/android-ndk.zip"
    local ndk_url="https://dl.google.com/android/repository/android-ndk-r27-linux.zip"
    info "下载 NDK 中（约 1.3GB，可能需要几分钟）..."
    if command -v curl &>/dev/null; then
        curl -L -o "$ndk_zip" "$ndk_url" --progress-bar
    elif command -v wget &>/dev/null; then
        wget -O "$ndk_zip" "$ndk_url" -q --show-progress
    else
        error "需要 curl 或 wget 来下载 NDK"
        exit 1
    fi
    info "解压 NDK..."
    unzip -q "$ndk_zip" -d "$WORK_DIR"
    NDK_DIR=$(ls -d "$WORK_DIR/android-ndk-r"* 2>/dev/null | head -1)
    if [ -z "$NDK_DIR" ] || [ ! -d "$NDK_DIR" ]; then
        error "NDK 解压失败"
        exit 1
    fi
    info "NDK 已准备就绪: $NDK_DIR"
}

# 克隆 SwiftShader 源码
clone_swiftshader() {
    if [ -d "$SWIFTSHADER_SRC" ]; then
        info "SwiftShader 源码已存在，更新中..."
        cd "$SWIFTSHADER_SRC"
        git pull --rebase
        cd "$SCRIPT_DIR"
    else
        info "克隆 SwiftShader 源码..."
        mkdir -p "$WORK_DIR"
        git clone --depth=1 https://swiftshader.googlesource.com/SwiftShader "$SWIFTSHADER_SRC"
        if [ $? -ne 0 ]; then
            # 备用源：GitHub mirror
            info "主源失败，尝试 GitHub mirror..."
            rm -rf "$SWIFTSHADER_SRC"
            git clone --depth=1 https://github.com/google/swiftshader.git "$SWIFTSHADER_SRC"
        fi
    fi
}

# 补丁 SwiftShader CMakeLists.txt - 添加 Android 平台支持
patch_swiftshader() {
    info "打补丁: 为 Android x86_64 添加 Vulkan 构建支持..."
    
    python3 -c "
import sys
src = sys.argv[1]

# Patch 1: 根 CMakeLists.txt - vk_base 平台检查
with open(src + '/CMakeLists.txt', 'r') as f:
    content = f.read()

old = '''elseif(FUCHSIA)
    target_compile_definitions(vk_base INTERFACE \"VK_USE_PLATFORM_FUCHSIA\")
else()
    message(FATAL_ERROR \"Platform does not support Vulkan yet\")
endif()'''

new = '''elseif(FUCHSIA)
    target_compile_definitions(vk_base INTERFACE \"VK_USE_PLATFORM_FUCHSIA\")
elseif(ANDROID)
    # Android uses Vulkan Loader ICD mechanism
else()
    message(FATAL_ERROR \"Platform does not support Vulkan yet\")
endif()'''

if old in content:
    content = content.replace(old, new, 1)
    with open(src + '/CMakeLists.txt', 'w') as f:
        f.write(content)
    print('  [OK] 根 CMakeLists.txt 已补丁')
else:
    print('  [!!] 根 CMakeLists.txt 未找到匹配模式，可能已被修改')
    sys.exit(1)

# Patch 2: src/Vulkan/CMakeLists.txt - VULKAN_API_LIBRARY_NAME
with open(src + '/src/Vulkan/CMakeLists.txt', 'r') as f:
    content = f.read()

old = '''elseif(FUCHSIA)
    set(VULKAN_API_LIBRARY_NAME \"libvulkan.so\")
else()
    message(FATAL_ERROR \"Platform does not support Vulkan yet\")
endif()'''

new = '''elseif(FUCHSIA)
    set(VULKAN_API_LIBRARY_NAME \"libvulkan.so\")
elseif(ANDROID)
    # SwiftShader on Android is loaded as an ICD, not a drop-in library
    set(VULKAN_API_LIBRARY_NAME \"\")
else()
    message(FATAL_ERROR \"Platform does not support Vulkan yet\")
endif()'''

if old in content:
    content = content.replace(old, new, 1)
    with open(src + '/src/Vulkan/CMakeLists.txt', 'w') as f:
        f.write(content)
    print('  [OK] src/Vulkan/CMakeLists.txt 已补丁')
else:
    print('  [!!] src/Vulkan/CMakeLists.txt 未找到匹配模式，可能已被修改')
    sys.exit(1)

print('补丁全部应用成功!')
" "$SWIFTSHADER_SRC"

    # 下载缺失的 Android 平台头文件（AOSP，NDK 不包含）
    download_aosp_header() {
        local rel_path="$1"   # 例如 vulkan/vk_android_native_buffer.h
        local aosp_url="$2"   # AOSP Gitiles URL (不含 ?format=TEXT)
        local dest="$SWIFTSHADER_SRC/include/$rel_path"
        mkdir -p "$(dirname "$dest")"
        if [ -f "$dest" ]; then
            info "  $rel_path 已存在，跳过"
            return 0
        fi
        info "  下载 $rel_path..."
        local full_url="${aosp_url}?format=TEXT"
        if command -v curl &>/dev/null; then
            curl -sL "$full_url" | base64 -d > "$dest" 2>/dev/null
        elif command -v wget &>/dev/null; then
            wget -qO- "$full_url" | base64 -d > "$dest" 2>/dev/null
        else
            python3 -c "
import urllib.request, base64, sys
url = '$full_url'
dest = '$dest'
try:
    resp = urllib.request.urlopen(url)
    with open(dest, 'wb') as f:
        f.write(base64.b64decode(resp.read()))
    print('  [OK] $rel_path 已下载')
except Exception as e:
    print(f'  [!!] 下载失败: {e}')
    sys.exit(1)
" || return 1
        fi
        if [ -f "$dest" ]; then
            info "  $rel_path 已就绪"
            return 0
        else
            error "  $rel_path 下载失败!"
            return 1
        fi
    }

    download_aosp_header "vulkan/vk_android_native_buffer.h" \
        "https://android.googlesource.com/platform/frameworks/native/+/refs/heads/main/vulkan/include/vulkan/vk_android_native_buffer.h"
    download_aosp_header "cutils/native_handle.h" \
        "https://android.googlesource.com/platform/system/core/+/refs/heads/main/libcutils/include/cutils/native_handle.h"
}

# 构建 SwiftShader
build_swiftshader() {
    local build_dir="$WORK_DIR/build_android_x64"
    mkdir -p "$build_dir"
    cd "$build_dir"
    
    info "开始配置 CMake (Android x86_64)..."
    cmake "$SWIFTSHADER_SRC" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK_DIR/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI=x86_64 \
        -DANDROID_PLATFORM=android-30 \
        -DSWIFTSHADER_BUILD_EGL=FALSE \
        -DSWIFTSHADER_BUILD_GLESv2=FALSE \
        -DSWIFTSHADER_BUILD_GLES_CM=FALSE \
        -DCMAKE_BUILD_TYPE=Release \
        -GNinja \
        -DSWIFTSHADER_WARNINGS_AS_ERRORS=FALSE
    
    info "开始编译 libvk_swiftshader.so..."
    ninja libvk_swiftshader.so
    if [ $? -ne 0 ]; then
        error "SwiftShader 编译失败"
        exit 1
    fi
    
    # 复制输出
    mkdir -p "$OUTPUT_DIR"
    cp "$build_dir/libvk_swiftshader.so" "$OUTPUT_DIR/"
    
    # 确认文件信息
    info "编译完成！"
    ls -lh "$OUTPUT_DIR/libvk_swiftshader.so"
    file "$OUTPUT_DIR/libvk_swiftshader.so"
}

# 主流程
main() {
    info "=== SwiftShader 构建脚本 ==="
    info "目标: Android x86_64 (WSA 运行架构)"
    echo ""
    
    check_dependencies
    setup_ndk
    clone_swiftshader
    patch_swiftshader
    build_swiftshader
    
    echo ""
    info "============================================"
    info "构建成功！"
    info "输出文件: $OUTPUT_DIR/libvk_swiftshader.so"
    info "下一步: 运行 install_vulkan.sh 安装到 WSA 镜像"
    info "============================================"
}

main "$@"
