#!/bin/bash

set -ex

WORKDIR=$(pwd)
mkdir -p "${WORKDIR}/output"

rm -f scripts/basic/fixdep
rm -f scripts/mod/modpost

#make ARCH=arm64 \
#  CROSS_COMPILE=aarch64-linux-gnu- \
#  KBUILD_BUILD_USER="builder" \
#  KBUILD_BUILD_HOST="kdevbuilder" \
#  LOCALVERSION=-kdev \
#  mrproper

# build kernel Image
make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  KBUILD_BUILD_USER="builder" \
  KBUILD_BUILD_HOST="kdevbuilder" \
  LOCALVERSION=-kdev \
  lz_d3588_defconfig

# check kver
KVER=$(make LOCALVERSION=-kdev kernelrelease)
KVER="${KVER/kdev*/kdev}"
if [[ "$KVER" != *kdev ]]; then
  echo "ERROR: KVER does not end with 'kdev'"
  exit 1
fi
echo "KVER: ${KVER}"

make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  KBUILD_BUILD_USER="builder" \
  KBUILD_BUILD_HOST="kdevbuilder" \
  LOCALVERSION=-kdev \
  dtbs \
   -j$(nproc)


make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  KBUILD_BUILD_USER="builder" \
  KBUILD_BUILD_HOST="kdevbuilder" \
  LOCALVERSION=-kdev \
  KCFLAGS="-Wno-unused-function" \
   -j$(nproc)

make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  KBUILD_BUILD_USER="builder" \
  KBUILD_BUILD_HOST="kdevbuilder" \
  LOCALVERSION=-kdev \
  KCFLAGS="-Wno-unused-function" \
  modules -j$(nproc)

make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  KBUILD_BUILD_USER="builder" \
  KBUILD_BUILD_HOST="kdevbuilder" \
  LOCALVERSION=-kdev \
  INSTALL_MOD_PATH=$(pwd)/kos \
  modules_install

# 安装内核头文件
make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  KBUILD_BUILD_USER="builder" \
  KBUILD_BUILD_HOST="kdevbuilder" \
  LOCALVERSION=-kdev \
  INSTALL_HDR_PATH="$(pwd)/kernel-headers/${KVER}" \
  headers_install

KVER=$(cat include/config/kernel.release)

# --- 内核镜像 ---
ls -alh arch/arm64/boot/Image
md5sum arch/arm64/boot/Image
cp -a arch/arm64/boot/Image "${WORKDIR}/output/Image"

# --- 设备树 ---
DTB_PATH="./arch/arm64/boot/dts/rockchip/rk3588-lz-d3588.dtb"
ls -alh "${DTB_PATH}"
md5sum "${DTB_PATH}"
cp -a "${DTB_PATH}" "${WORKDIR}/output/"

# --- 内核配置文件 ---
cp .config "${WORKDIR}/output/config"
ls -alh "${WORKDIR}/output/config"
md5sum "${WORKDIR}/output/config"

# --- System.map ---
cp System.map "${WORKDIR}/output/System.map"
ls -alh "${WORKDIR}/output/System.map"
md5sum "${WORKDIR}/output/System.map"

# --- 内核模块打包（strip 版本 + debug 版本）---
if [ -d kos/lib/modules ]; then
  dir_size=$(du -sb kos/lib/modules | awk '{print $1}')
  if [ "$dir_size" -gt 512 ]; then
    # 保留一份未 strip 的调试副本
    cp -a kos kos-debug
    # 对发布版模块去除调试符号以减小体积
    find kos -name "*.ko" -print0 | xargs -0 -r aarch64-linux-gnu-strip --strip-debug
    find kos -name "*.ko"
    ls -alh kos/lib/modules/
    mkdir -p "${WORKDIR}/output"
    tar -zcvf "${WORKDIR}/output/kos-6.1.tar.gz" kos
  fi
fi

# --- 内核调试信息归档 ---
if [ -f vmlinux ]; then
  mkdir -p "${WORKDIR}/output"
  DEBUGINFO_FILES=()
  for f in vmlinux vmlinux.unstripped System.map Module.symvers .config kos-debug; do
    [ -f "$f" ] && DEBUGINFO_FILES+=("$f")
  done

  if [ ${#DEBUGINFO_FILES[@]} -gt 0 ]; then
    tar -zcvf "${WORKDIR}/output/kernel-debuginfo-6.1.tar.gz" "${DEBUGINFO_FILES[@]}"
    echo "Kernel debuginfo archived: ${DEBUGINFO_FILES[*]}"
  else
    echo "No debuginfo files found to archive"
  fi
fi

if [ -d kernel-headers ]; then
  mkdir -p "${WORKDIR}/output"
  tar -zcvf "${WORKDIR}/output/kernel-headers-6.1.tar.gz" kernel-headers
fi

cd "${WORKDIR}/${KERNEL_SRC_DIR}"

ARCH="arm64"
DEVEL_DIR="${WORKDIR}/kernel-devel/${KVER}"

# 重新交叉编译 fixdep 和 modpost，确保它们是 arm64 二进制
# （这两个工具在外部模块编译时会被调用）
rm -f scripts/basic/fixdep
aarch64-linux-gnu-gcc -Wall \
  -Wmissing-prototypes -Wstrict-prototypes -O2 \
  -I scripts/include \
  -o scripts/basic/fixdep \
  scripts/basic/fixdep.c

rm -f scripts/mod/modpost
aarch64-linux-gnu-gcc -Wall \
  -Wmissing-prototypes -Wstrict-prototypes -O2 \
  -I scripts/include \
  -o scripts/mod/modpost \
  scripts/mod/modpost.c \
  scripts/mod/sumversion.c \
  scripts/mod/file2alias.c

# 清理旧的 devel 目录并重建结构
rm -rf "${DEVEL_DIR}"
mkdir -p "${DEVEL_DIR}/arch/${ARCH}"
mkdir -p "${DEVEL_DIR}/include"
mkdir -p "${DEVEL_DIR}/scripts"
mkdir -p "${DEVEL_DIR}/tools"

# 复制顶层构建文件
cp -a Makefile "${DEVEL_DIR}/"
cp -a Kbuild "${DEVEL_DIR}/"

for f in Module.symvers System.map .config; do
  [ -f "$f" ] && cp -a "$f" "${DEVEL_DIR}/"
done

# 复制 scripts 目录（含编译好的 fixdep/modpost）
cp -a scripts "${DEVEL_DIR}/"

# 复制架构相关脚本
if [ -d "arch/${ARCH}/scripts" ]; then
  mkdir -p "${DEVEL_DIR}/arch/${ARCH}"
  cp -a "arch/${ARCH}/scripts" "${DEVEL_DIR}/arch/${ARCH}/"
fi

# 复制模块链接脚本
if [ -f "scripts/module.lds" ]; then
  mkdir -p "${DEVEL_DIR}/scripts"
  cp -a scripts/module.lds "${DEVEL_DIR}/scripts/"
fi

# 复制头文件
cp -a include "${DEVEL_DIR}/"
if [ -d "arch/${ARCH}/include" ]; then
  cp -a "arch/${ARCH}/include" "${DEVEL_DIR}/arch/${ARCH}/"
fi

# 复制架构 Makefile
if [ -f "arch/${ARCH}/Makefile" ]; then
  cp -a "arch/${ARCH}/Makefile" "${DEVEL_DIR}/arch/${ARCH}/"
fi

# 复制链接器脚本
for lds in arch/${ARCH}/*.lds; do
  [ -f "$lds" ] && cp -a "$lds" "${DEVEL_DIR}/arch/${ARCH}/"
done

# 复制设备树源文件（供外部模块引用 DTS 头文件）
if [ -d "arch/${ARCH}/boot/dts" ]; then
  mkdir -p "${DEVEL_DIR}/arch/${ARCH}/boot/dts"
  find "arch/${ARCH}/boot/dts" \
    \( -name '*.dts' -o -name '*.dtsi' -o -name '*.h' \
    -o -name 'Makefile' -o -name 'Kconfig' -o -name '*.overlay' \) \
    -type f \
    -exec cp --parents {} "${DEVEL_DIR}/" \;
fi

# ARM64 兼容层：复制 arm/include/asm（部分驱动需要）
if [ "${ARCH}" = "arm64" ] && [ -d "arch/arm/include/asm" ]; then
  mkdir -p "${DEVEL_DIR}/arch/arm/include"
  cp -a arch/arm/include/asm "${DEVEL_DIR}/arch/arm/include/"
fi

# 递归复制所有 Makefile/Kconfig/Kbuild 文件（排除已复制目录和 .git）
find . -type f \( -name "Makefile" -o -name "Makefile.*" \
  -o -name "Kconfig" -o -name "Kconfig.*" \
  -o -name "Kbuild" -o -name "Kbuild.*" \) \
  ! -path './kernel-devel/*' \
  ! -path './.git/*' \
  -exec cp --parents {} "${DEVEL_DIR}/" \;

# 如果启用了 objtool，复制其二进制
if grep -q 'CONFIG_OBJTOOL=y' .config 2>/dev/null; then
  if [ -f tools/objtool/objtool ]; then
    mkdir -p "${DEVEL_DIR}/tools/objtool"
    cp -a tools/objtool/objtool "${DEVEL_DIR}/tools/objtool/"
  fi
fi

# 清理 devel 包中不需要的中间文件和临时文件
find "${DEVEL_DIR}" -name ".*.cmd" -delete 2>/dev/null || true
find "${DEVEL_DIR}/scripts" -name "*.o" -delete 2>/dev/null || true
find "${DEVEL_DIR}" -name "*.dtb" -delete 2>/dev/null || true
find "${DEVEL_DIR}" -name "*.dtbo" -delete 2>/dev/null || true
find "${DEVEL_DIR}" -name ".tmp_*" -delete 2>/dev/null || true
find "${DEVEL_DIR}" -name "*.tmp" -delete 2>/dev/null || true
find "${DEVEL_DIR}" -type d -empty -delete 2>/dev/null || true

# 同步关键生成文件的时间戳，避免外部模块编译时触发不必要的重编
if [ -f "${DEVEL_DIR}/include/generated/utsrelease.h" ]; then
  touch -r Makefile "${DEVEL_DIR}/include/generated/utsrelease.h"
fi
if [ -f "${DEVEL_DIR}/include/generated/autoconf.h" ]; then
  touch -r .config "${DEVEL_DIR}/include/generated/autoconf.h"
fi
if [ -f "${DEVEL_DIR}/include/config/auto.conf" ]; then
  touch -r .config "${DEVEL_DIR}/include/config/auto.conf"
fi

# 兜底：确保 auto.conf 存在
if [ ! -f "${DEVEL_DIR}/include/config/auto.conf" ]; then
  mkdir -p "${DEVEL_DIR}/include/config"
  cp .config "${DEVEL_DIR}/include/config/auto.conf"
fi

# 打包 kernel-devel
cd "${WORKDIR}"
tar -czf "${WORKDIR}/output/kernel-devel-6.1.tar.gz" kernel-devel

ls -alh "${WORKDIR}/output/"

echo "All done!All ok!"

