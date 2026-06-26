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

    # 创建 vk_android_native_buffer.h 兼容 stub
    # 不直接从 AOSP main 下载，因为 AOSP 版本依赖 NDK 未定义的类型
    # 改用 SwiftShader 自带的 vulkan_android.h 提供 VkAndroidHardwareBufferUsageANDROID
    local nb_path="$SWIFTSHADER_SRC/include/vulkan/vk_android_native_buffer.h"
    if [ ! -f "$nb_path" ]; then
        info "创建 vk_android_native_buffer.h 兼容 stub..."
        mkdir -p "$SWIFTSHADER_SRC/include/vulkan"
        cat > "$nb_path" << 'STUBEOF'
/*
 * vk_android_native_buffer.h 兼容性 stub
 *
 * 为 SwiftShader 在 Android x86_64 交叉编译环境中
 * 提供 VK_ANDROID_native_buffer 扩展类型定义。
 *
 * 包含 NDK 的 <vulkan/vulkan.h> 获取基础 Vulkan 类型，
 * 并补充 NDK API 30 未包含的 Android 扩展类型。
 */

#ifndef __VK_ANDROID_NATIVE_BUFFER_H__
#define __VK_ANDROID_NATIVE_BUFFER_H__

#include <cutils/native_handle.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- VK_ANDROID_external_memory_android_hardware_buffer (补充定义) ---- */
/* SwiftShader 的 vulkan_android.h 定义了此类型，但依赖 Vulkan 1.3    */
/* NDK r27 API 30 不包含此类型，在此自行定义                           */
typedef struct VkAndroidHardwareBufferUsageANDROID {
    VkStructureType sType;
    void* pNext;
    uint64_t androidHardwareBufferUsage;
} VkAndroidHardwareBufferUsageANDROID;

/* ---- VK_ANDROID_native_buffer 扩展 ---- */
#define VK_ANDROID_native_buffer 1
#define VK_ANDROID_NATIVE_BUFFER_EXTENSION_NUMBER 11
#define VK_ANDROID_NATIVE_BUFFER_SPEC_VERSION 11
#define VK_ANDROID_NATIVE_BUFFER_EXTENSION_NAME "VK_ANDROID_native_buffer"

#define VK_ANDROID_NATIVE_BUFFER_ENUM(type, id) \
    ((type)(1000000000 + \
    (1000 * (VK_ANDROID_NATIVE_BUFFER_EXTENSION_NUMBER - 1)) + (id)))

#define VK_STRUCTURE_TYPE_NATIVE_BUFFER_ANDROID \
    VK_ANDROID_NATIVE_BUFFER_ENUM(VkStructureType, 0)
#define VK_STRUCTURE_TYPE_SWAPCHAIN_IMAGE_CREATE_INFO_ANDROID \
    VK_ANDROID_NATIVE_BUFFER_ENUM(VkStructureType, 1)
#define VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENTATION_PROPERTIES_ANDROID \
    VK_ANDROID_NATIVE_BUFFER_ENUM(VkStructureType, 2)
#define VK_STRUCTURE_TYPE_GRALLOC_USAGE_INFO_ANDROID \
    VK_ANDROID_NATIVE_BUFFER_ENUM(VkStructureType, 3)
#define VK_STRUCTURE_TYPE_GRALLOC_USAGE_INFO_2_ANDROID \
    VK_ANDROID_NATIVE_BUFFER_ENUM(VkStructureType, 4)

typedef enum VkSwapchainImageUsageFlagBitsANDROID {
    VK_SWAPCHAIN_IMAGE_USAGE_SHARED_BIT_ANDROID = 0x00000001,
    VK_SWAPCHAIN_IMAGE_USAGE_FLAG_BITS_MAX_ENUM = 0x7FFFFFFF
} VkSwapchainImageUsageFlagBitsANDROID;
typedef VkFlags VkSwapchainImageUsageFlagsANDROID;

typedef struct {
    uint64_t consumer;
    uint64_t producer;
} VkNativeBufferUsage2ANDROID;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    buffer_handle_t handle;
    int stride;
    int format;
    int usage;
    VkNativeBufferUsage2ANDROID usage2;
    uint64_t usage3;
    struct AHardwareBuffer* ahb;
} VkNativeBufferANDROID;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkSwapchainImageUsageFlagsANDROID usage;
} VkSwapchainImageCreateInfoANDROID;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkBool32 sharedImage;
} VkPhysicalDevicePresentationPropertiesANDROID;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFormat format;
    VkImageUsageFlags imageUsage;
} VkGrallocUsageInfoANDROID;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFormat format;
    VkImageUsageFlags imageUsage;
    VkSwapchainImageUsageFlagsANDROID swapchainImageUsage;
} VkGrallocUsageInfo2ANDROID;

typedef VkResult (VKAPI_PTR *PFN_vkGetSwapchainGrallocUsageANDROID)(
    VkDevice, VkFormat, VkImageUsageFlags, int*);
typedef VkResult (VKAPI_PTR *PFN_vkGetSwapchainGrallocUsage2ANDROID)(
    VkDevice, VkFormat, VkImageUsageFlags,
    VkSwapchainImageUsageFlagsANDROID, uint64_t*, uint64_t*);
typedef VkResult (VKAPI_PTR *PFN_vkGetSwapchainGrallocUsage3ANDROID)(
    VkDevice, const VkGrallocUsageInfoANDROID*, uint64_t*);
typedef VkResult (VKAPI_PTR *PFN_vkGetSwapchainGrallocUsage4ANDROID)(
    VkDevice, const VkGrallocUsageInfo2ANDROID*, uint64_t*);
typedef VkResult (VKAPI_PTR *PFN_vkAcquireImageANDROID)(
    VkDevice, VkImage, int, VkSemaphore, VkFence);
typedef VkResult (VKAPI_PTR *PFN_vkQueueSignalReleaseImageANDROID)(
    VkQueue, uint32_t, const VkSemaphore*, VkImage, int*);

#ifdef __cplusplus
}
#endif

#endif /* __VK_ANDROID_NATIVE_BUFFER_H__ */
STUBEOF
        if [ -f "$nb_path" ]; then
            info "vk_android_native_buffer.h stub 已创建"
        else
            error "vk_android_native_buffer.h stub 创建失败!"
            exit 1
        fi
    else
        info "vk_android_native_buffer.h 已存在，跳过创建"
    fi

    # 下载 cutils/native_handle.h（AOSP system/core，NDK 不包含）
    download_cutils_header() {
        local dest="$SWIFTSHADER_SRC/include/cutils/native_handle.h"
        mkdir -p "$(dirname "$dest")"
        if [ -f "$dest" ]; then
            info "  cutils/native_handle.h 已存在，跳过"
            return 0
        fi
        info "  下载 cutils/native_handle.h (来自 AOSP)..."
        local aosp_url="https://android.googlesource.com/platform/system/core/+/refs/heads/main/libcutils/include/cutils/native_handle.h?format=TEXT"
        if command -v curl &>/dev/null; then
            curl -sL "$aosp_url" | base64 -d > "$dest" 2>/dev/null
        elif command -v wget &>/dev/null; then
            wget -qO- "$aosp_url" | base64 -d > "$dest" 2>/dev/null
        else
            python3 -c "
import urllib.request, base64, sys
url = '$aosp_url'
path = '$dest'
try:
    resp = urllib.request.urlopen(url)
    with open(path, 'wb') as f:
        f.write(base64.b64decode(resp.read()))
    print('  [OK] cutils/native_handle.h 已下载')
except Exception as e:
    print(f'  [!!] 下载失败: {e}')
    sys.exit(1)
" || return 1
        fi
        if [ -f "$dest" ]; then
            info "  cutils/native_handle.h 已就绪"
            return 0
        else
            error "  cutils/native_handle.h 下载失败!"
            exit 1
        fi
    }
    download_cutils_header

    # 下载 Android 平台头文件（NDK 不包含 hardware/gralloc.h 等）
    download_android_headers() {
        info "下载 Android 平台头文件 (来自 AOSP)..."
        local headers=(
            "hardware/gralloc.h:https://android.googlesource.com/platform/hardware/libhardware/+/refs/heads/main/include/hardware/gralloc.h?format=TEXT"
            "hardware/gralloc1.h:https://android.googlesource.com/platform/hardware/libhardware/+/refs/heads/main/include/hardware/gralloc1.h?format=TEXT"
            "sync/sync.h:https://android.googlesource.com/platform/system/core/+/refs/heads/main/libsync/include/sync/sync.h?format=TEXT"
        )
        for entry in "${headers[@]}"; do
            local relpath="${entry%%:*}"
            local url="${entry#*:}"
            local dest="$SWIFTSHADER_SRC/include/$relpath"
            mkdir -p "$(dirname "$dest")"
            if [ -f "$dest" ]; then
                info "  $relpath 已存在，跳过"
                continue
            fi
            info "  下载 $relpath..."
            if command -v curl &>/dev/null; then
                curl -sL "$url" | base64 -d > "$dest" 2>/dev/null
            elif command -v wget &>/dev/null; then
                wget -qO- "$url" | base64 -d > "$dest" 2>/dev/null
            else
                python3 -c "
import urllib.request, base64, sys
url = '$url'
path = '$dest'
try:
    resp = urllib.request.urlopen(url)
    with open(path, 'wb') as f:
        f.write(base64.b64decode(resp.read()))
    print('  [OK] $relpath 已下载')
except Exception as e:
    print(f'  [!!] 下载失败 $relpath: {e}')
    sys.exit(1)
" || return 1
            fi
            if [ -f "$dest" ]; then
                info "  $relpath 已就绪"
            else
                error "  $relpath 下载失败!"
                exit 1
            fi
        done
        info "  所有 Android 平台头文件已就绪"
    }
    download_android_headers
}

# 构建 SwiftShader
build_swiftshader() {
    local build_dir="$WORK_DIR/build_android_x64"
    mkdir -p "$build_dir"
    cd "$build_dir"
    
    # 生成 commit.h（版本信息头文件，Android 构建需要此文件但 CMake 不会自动生成）
    info "生成 commit.h..."
    python3 "$SWIFTSHADER_SRC/src/commit_id.py" gen "$SWIFTSHADER_SRC/src/Vulkan/commit.h" 2>/dev/null || {
        warn "commit_id.py 执行失败，创建默认版本..."
        cat > "$SWIFTSHADER_SRC/src/Vulkan/commit.h" << 'COMMITEOF'
#define SWIFTSHADER_COMMIT_HASH "wsa-build"
#define SWIFTSHADER_COMMIT_HASH_SIZE 12
#define SWIFTSHADER_COMMIT_DATE "2024-01-01 00:00:00 +0000"
#define SWIFTSHADER_VERSION_STRING \
    MACRO_STRINGIFY(MAJOR_VERSION) "."  \
    MACRO_STRINGIFY(MINOR_VERSION) "."  \
    MACRO_STRINGIFY(PATCH_VERSION) "."  \
    SWIFTSHADER_COMMIT_HASH
COMMITEOF
        info "  默认 commit.h 已创建"
    }
    info "  commit.h 已就绪"

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
