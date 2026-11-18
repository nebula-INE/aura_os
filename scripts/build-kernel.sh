#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../kernel/linux-version.env
source "${ROOT_DIR}/kernel/linux-version.env"

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
WORK_DIR="${ROOT_DIR}/build/kernel-src"
OUT_DIR="${ROOT_DIR}/build/kernel"
ARCH="${ARCH:-x86}"
TARBALL="linux-${LINUX_KERNEL_VERSION}.tar.xz"
BASE_URL="https://cdn.kernel.org/pub/linux/kernel/v${LINUX_KERNEL_SERIES}"
SOURCE_DIR="${WORK_DIR}/linux-${LINUX_KERNEL_VERSION}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in curl tar make perl; do
  require_command "$cmd"
done

if [[ "${ARCH}" != "x86" ]]; then
  echo "error: this initial script supports ARCH=x86 only; RV64GC and AArch64 are planned next." >&2
  exit 2
fi

mkdir -p "${WORK_DIR}" "${OUT_DIR}"

if [[ ! -d "${SOURCE_DIR}" ]]; then
  archive="${WORK_DIR}/${TARBALL}"
  if [[ ! -f "${archive}" ]]; then
    echo "Downloading upstream Linux ${LINUX_KERNEL_VERSION}..."
    curl --fail --location --retry 3 --output "${archive}.part" "${BASE_URL}/${TARBALL}"
    mv "${archive}.part" "${archive}"
  fi
  echo "Extracting ${TARBALL}..."
  tar -C "${WORK_DIR}" -xf "${archive}"
fi

if [[ ! -f "${SOURCE_DIR}/Makefile" ]]; then
  echo "error: extracted kernel source is incomplete: ${SOURCE_DIR}" >&2
  exit 1
fi

echo "Configuring Linux ${LINUX_KERNEL_VERSION} for x86-64 QEMU..."
make -C "${SOURCE_DIR}" O="${OUT_DIR}" ARCH=x86 x86_64_defconfig
"${SOURCE_DIR}/scripts/kconfig/merge_config.sh" -m -O "${OUT_DIR}" \
  "${OUT_DIR}/.config" "${ROOT_DIR}/kernel/configs/x86_64_qemu.fragment"
make -C "${SOURCE_DIR}" O="${OUT_DIR}" ARCH=x86 olddefconfig

echo "Building bzImage with ${JOBS} job(s)..."
make -C "${SOURCE_DIR}" O="${OUT_DIR}" ARCH=x86 -j"${JOBS}" bzImage

IMAGE="${OUT_DIR}/arch/x86/boot/bzImage"
test -s "${IMAGE}"
sha256sum "${IMAGE}" | tee "${OUT_DIR}/bzImage.sha256"
printf '\nKernel build complete: %s\n' "${IMAGE}"
