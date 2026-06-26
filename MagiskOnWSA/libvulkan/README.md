# Vulkan 软件驱动模块 (SwiftShader)

## 概述

本模块为 WSA (Windows Subsystem for Android) 提供纯 CPU 渲染的 Vulkan 实现，解决 **GPU-PV (GPU Paravirtualization)** 初始化失败导致的 Unity/URP 应用 ANR 问题。

### 解决的核心问题

当 Windows 主机的 GPU-PV 不可用时（如旧显卡、Hyper-V 配置问题、驱动不兼容），WSA 的 virtgpu 内核驱动会报错:
```
DRM_IOCTL_VIRTGPU_CONTEXT_INIT failed with Invalid argument
```

这导致 Unity URP 等图形引擎无法初始化 Vulkan/GLES 硬件加速，回退到软件渲染但仍试图使用 GLES 3.1+，最终因 `EGL_BAD_CONFIG` 和 700%+ CPU 占用而 ANR。

### 解决方案

通过注入 **SwiftShader**（Google 开源的 Vulkan 1.1 软件实现）到 WSA 的 vendor 镜像，Unity 等应用将检测到一个可用的 Vulkan 物理设备，所有渲染通过 CPU 完成。

## 架构

```
Unity App (ARM64)
    ↓ Houdini (ARM→x86 翻译)
Vulkan API 调用
    ↓
Android Vulkan Loader (libvulkan.so)
    ↓
SwiftShader (libvk_swiftshader.so)  ← 本模块注入
    ↓
CPU 软件光栅化 (LLVM JIT)
    ↓
帧缓冲输出到 EGL_emulation
```

## 文件说明

| 文件 | 用途 |
|------|------|
| `build_swiftshader.sh` | 编译 SwiftShader for Android x86_64 |
| `install_vulkan.sh` | 安装 SwiftShader 到已构建的 WSA 镜像 |
| `vk_swiftshader_x86_64.json` | Vulkan ICD 清单，Vulkan 加载器通过它发现驱动 |
| `output/libvk_swiftshader.so` | 编译产物（运行 build_swiftshader.sh 后产生） |

## 构建前置条件

- **Linux 环境**（WSL2 或 Ubuntu 22.04+）
- Android NDK r25+（脚本会自动下载）
- CMake 3.21+
- Ninja 构建系统
- Python 3
- Git

```bash
# 安装依赖 (Ubuntu/Debian)
sudo apt install cmake ninja-build python3 git openssl libssl-dev
```

## 使用方式

### 方式 1: 自动集成到完整构建

在运行 `build.sh` 之后、`houdini_installer.sh` 之前，运行:

```bash
cd MagiskOnWSA

# 1. 构建 SwiftShader
bash libvulkan/build_swiftshader.sh

# 2. 运行 Houdini 安装（会自动检测并安装 SwiftShader）
bash libhoudini/houdini_installer.sh <artifact_folder>
```

### 方式 2: 独立安装到已有镜像

如果已有构建好的 WSA 镜像:

```bash
cd MagiskOnWSA

# 先构建 SwiftShader
bash libvulkan/build_swiftshader.sh

# 然后安装
bash libvulkan/install_vulkan.sh <artifact_folder>
```

### 方式 3: GitHub Actions CI

在工作流中已自动包含 SwiftShader 构建步骤。提交代码后，CI 会自动构建并注入 SwiftShader。

## SwiftShader 技术详情

- **项目**: https://swiftshader.googlesource.com/SwiftShader
- **许可证**: Apache 2.0
- **Vulkan 版本**: 1.1
- **渲染方式**: LLVM JIT 编译着色器，CPU 多线程光栅化
- **适用架构**: x86_64（本构建），也支持 ARM64

SwiftShader 由 Google 开发，用于:
- Android 模拟器（API 33+ 默认使用 SwiftShader 作为软件渲染器）
- Google Chrome/Chromium（WebGL 回退）
- 云游戏场景

## 性能说明

SwiftShader 是 CPU 渲染，性能远低于物理 GPU:
- 简单 2D UI 可以流畅运行
- 简单 3D 场景（如 Unity URP 空白模板）可用但帧率较低
- 复杂 3D 游戏不建议使用

这是 GPU-PV 损坏时的最佳可行方案，比纯 GLES 软件渲染更兼容（Unity URP 优先使用 Vulkan）。

## 验证安装

在 WSA 的 adb shell 中:

```bash
# 检查 Vulkan ICD 是否注册
adb shell ls -l /vendor/etc/vulkan/icd.d/
# 应看到 vk_swiftshader.json

# 检查 SwiftShader 库
adb shell ls -l /vendor/lib64/libvk_swiftshader.so

# 测试 Vulkan 枚举（需要安装 vulkan-tools）
adb shell /data/local/tmp/vulkaninfo 2>/dev/null | head -30
# 应看到 SwiftShader 设备信息
```
