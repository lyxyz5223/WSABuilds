#!/bin/sh
MAGISKTMP=/sbin
[ -d /sbin ] || MAGISKTMP=/debug_ramdisk
MAGISKBIN=/data/adb/magisk
if [ ! -d /data/adb ]; then
    mkdir -m 700 /data/adb
    chcon u:object_r:adb_data_file:s0 /data/adb
fi
if [ ! -d $MAGISKBIN ]; then
    # shellcheck disable=SC2174
    mkdir -p -m 755 $MAGISKBIN
    chcon u:object_r:system_file:s0 $MAGISKBIN
fi
ABI=$(getprop ro.product.cpu.abi)
for file in busybox magiskpolicy magiskboot magiskinit; do
    [ -x "$MAGISKBIN/$file" ] || {
        unzip -d $MAGISKBIN -oj $MAGISKTMP/stub.apk "lib/$ABI/lib$file.so"
        mv $MAGISKBIN/lib$file.so $MAGISKBIN/$file
        chmod 755 "$MAGISKBIN/$file"
    }
done
for file in util_functions.sh boot_patch.sh; do
    [ -x "$MAGISKBIN/$file" ] || {
        unzip -d $MAGISKBIN -oj $MAGISKTMP/stub.apk "assets/$file"
        chmod 755 "$MAGISKBIN/$file"
    }
done
for file in "$MAGISKTMP"/*; do
    if echo "$file" | grep -Eq "lsp_.+\.img"; then
        foldername=$(basename "$file" .img)
        mkdir -p "$MAGISKTMP/$foldername"
        mount -t auto -o ro,loop "$file" "$MAGISKTMP/$foldername"
        "$MAGISKTMP/$foldername/post-fs-data.sh" &
    fi
done
wait
for file in "$MAGISKTMP"/*; do
    if echo "$file" | grep -Eq "lsp_.+\.img"; then
        foldername=$(basename "$file" .img)
        umount "$MAGISKTMP/$foldername"
        rm -rf "${MAGISKTMP:?}/${foldername:?}"
        rm -f "$file"
    fi
done

# ===== WSA GPU/GPU-PV 修复 (Magisk resetprop 兜底) =====
# 目的:
#   当 GPU-PV (virtgpu) 在 Windows 主机端初始化失败时，
#   通过 Magisk resetprop 强制覆盖系统属性，确保:
#   - 系统不使用损坏的 virtgpu 后端
#   - GLES 版本限制为 3.0 (196608)，匹配 EGL_emulation 能力
#   - 不清除 Vulkan 支持 — 由 libvk_swiftshader.so (SwiftShader) 提供
#
# 优先使用 $MAGISKTMP/resetprop, 回退到 $MAGISKBIN/resetprop 或 PATH
RESETPROP=$MAGISKTMP/resetprop
if [ ! -x "$RESETPROP" ]; then
    RESETPROP=$MAGISKBIN/resetprop
fi
if [ ! -x "$RESETPROP" ]; then
    RESETPROP=$(command -v resetprop 2>/dev/null)
fi
if [ -x "$RESETPROP" ]; then
    # 禁用 virtgpu 后端（init.rc 层已设置，这里二次保障）
    "$RESETPROP" ro.boot.virtgpu_disable 1
    "$RESETPROP" ro.config.virtgpu false
    "$RESETPROP" vendor.gralloc.disable_virtgpu 1

    # 限制 GLES 版本为 3.0 （避免 Unity 请求不存在的 GLES 3.1/3.2）
    "$RESETPROP" ro.opengles.version 196608

    # 禁用可更新的 GPU 驱动（使用 vendor 内置驱动/SwiftShader）
    "$RESETPROP" ro.gfx.driver.0 ""
    "$RESETPROP" ro.gfx.driver.1 ""

    # 注意: 不设置 ro.config.vulkan.disable=true
    # libvk_swiftshader.so 已作为 Vulkan ICD 注入 vendor 分区

    # GPU 超时乘数，给 Unity 更多响应时间
    "$RESETPROP" ro.hw_timeout_multiplier 5

    log -p i -t WSA-GPU-FIX "Applied GPU fix: virtgpu off, GLES 3.0, SwiftShader Vulkan"
else
    log -p w -t WSA-GPU-FIX "resetprop not found, GPU properties not force-set"
fi
