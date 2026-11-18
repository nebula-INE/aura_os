#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../kernel/linux-version.env
source "${ROOT_DIR}/kernel/linux-version.env"

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
WORK_DIR="${ROOT_DIR}/build/kernel-src"
OUT_DIR="${ROOT_DIR}/build/kernel"
KEYRING_DIR="${WORK_DIR}/gnupg"
SOURCE_DIR="${WORK_DIR}/linux-${LINUX_KERNEL_VERSION}-git"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"

case "${TARGET_ARCH}" in
  x86_64)
    ARCH="x86"
    DEFCONFIG="x86_64_defconfig"
    FRAGMENT="${ROOT_DIR}/kernel/configs/x86_64_qemu.fragment"
    IMAGE_TARGET="bzImage"
    IMAGE_RELATIVE_PATH="arch/x86/boot/bzImage"
    CROSS_COMPILE="${CROSS_COMPILE:-}"
    ;;
  riscv64)
    ARCH="riscv"
    DEFCONFIG="defconfig"
    FRAGMENT="${ROOT_DIR}/kernel/configs/riscv64_qemu.fragment"
    IMAGE_TARGET="Image"
    IMAGE_RELATIVE_PATH="arch/riscv/boot/Image"
    CROSS_COMPILE="${CROSS_COMPILE:-riscv64-linux-gnu-}"
    ;;
  aarch64)
    ARCH="arm64"
    DEFCONFIG="defconfig"
    FRAGMENT="${ROOT_DIR}/kernel/configs/aarch64_qemu.fragment"
    IMAGE_TARGET="Image"
    IMAGE_RELATIVE_PATH="arch/arm64/boot/Image"
    CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
    ;;
  *)
    echo "error: TARGET_ARCH must be x86_64, riscv64, or aarch64." >&2
    exit 2
    ;;
esac
export ARCH CROSS_COMPILE

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

COMPILER="${CROSS_COMPILE}gcc"
for cmd in git gpg curl awk grep make perl tr "$COMPILER"; do
  require_command "$cmd"
done

mkdir -p "$WORK_DIR" "$OUT_DIR" "$KEYRING_DIR"
chmod 700 "$KEYRING_DIR"
export GNUPGHOME="$KEYRING_DIR"
EXPECTED_FINGERPRINT="$(printf '%s' "$LINUX_KERNEL_SIGNING_KEY_FINGERPRINT" | tr '[:lower:]' '[:upper:]')"
SIGNING_KEY_ID="${EXPECTED_FINGERPRINT: -16}"

fingerprint_is_present() {
  gpg --batch --with-colons --list-keys 2>/dev/null |
    awk -F: -v expected="$EXPECTED_FINGERPRINT" '$1 == "fpr" && toupper($10) == expected { found = 1 } END { exit !found }'
}

fetch_and_check_key() {
  local url="$1"
  local key_file="${WORK_DIR}/linux-stable-maintainer-key.asc"
  if curl --fail --location --retry 2 --connect-timeout 10 --max-time 45 \
    --output "$key_file" "$url" &&
    gpg --batch --import "$key_file" &&
    fingerprint_is_present; then
    return 0
  fi
  return 1
}

echo "Importing the Linux stable maintainer key through kernel.org WKD..."
if ! gpg --batch --locate-keys "$LINUX_KERNEL_SIGNER" || ! fingerprint_is_present; then
  echo "warning: kernel.org WKD did not provide the pinned key; trying kernel.org's published keyring." >&2
  if ! fetch_and_check_key "https://git.kernel.org/pub/scm/docs/kernel/pgpkeys.git/plain/keys/${SIGNING_KEY_ID}.asc"; then
    echo "warning: kernel.org keyring lookup failed; trying the Ubuntu OpenPGP keyserver." >&2
    if ! fetch_and_check_key "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${EXPECTED_FINGERPRINT}"; then
      echo "error: unable to retrieve the pinned signing key from trusted key sources." >&2
      exit 1
    fi
  fi
fi

if ! fingerprint_is_present; then
  echo "error: no imported key matches the pinned kernel.org fingerprint." >&2
  echo "Expected: ${EXPECTED_FINGERPRINT}" >&2
  exit 1
fi

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  rm -rf "$SOURCE_DIR"
  echo "Cloning upstream Linux tag ${LINUX_KERNEL_TAG}..."
  git clone --depth 1 --single-branch --branch "$LINUX_KERNEL_TAG" \
    "$LINUX_KERNEL_REPOSITORY" "$SOURCE_DIR"
else
  origin="$(git -C "$SOURCE_DIR" remote get-url origin)"
  if [[ "$origin" != "$LINUX_KERNEL_REPOSITORY" ]]; then
    echo "error: cached kernel source has an unexpected origin: $origin" >&2
    exit 1
  fi
  git -C "$SOURCE_DIR" fetch --depth 1 origin \
    "refs/tags/${LINUX_KERNEL_TAG}:refs/tags/${LINUX_KERNEL_TAG}"
fi

echo "Verifying signed upstream tag ${LINUX_KERNEL_TAG}..."
if ! verify_output="$(git -C "$SOURCE_DIR" verify-tag --raw "$LINUX_KERNEL_TAG" 2>&1)"; then
  printf '%s\n' "$verify_output" >&2
  echo "error: upstream Linux tag signature verification failed." >&2
  exit 1
fi
printf '%s\n' "$verify_output"
if ! grep -Fq "[GNUPG:] VALIDSIG ${EXPECTED_FINGERPRINT}" <<<"$verify_output"; then
  echo "error: the signed tag was not made by the pinned stable maintainer key." >&2
  exit 1
fi

git -C "$SOURCE_DIR" checkout --detach --force "$LINUX_KERNEL_TAG"
git -C "$SOURCE_DIR" clean -fdx
SOURCE_COMMIT="$(git -C "$SOURCE_DIR" rev-parse "${LINUX_KERNEL_TAG}^{commit}")"
CURRENT_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$SOURCE_COMMIT" != "$CURRENT_COMMIT" ]]; then
  echo "error: checked out source does not match the verified tag." >&2
  exit 1
fi

{
  printf 'Target architecture: %s\n' "$TARGET_ARCH"
  printf 'Kernel ARCH: %s\n' "$ARCH"
  printf 'Cross compiler prefix: %s\n' "$CROSS_COMPILE"
  printf 'Compiler: %s\n' "$("$COMPILER" --version | head -n 1)"
  printf 'Linux version: %s\n' "$LINUX_KERNEL_VERSION"
  printf 'Git tag: %s\n' "$LINUX_KERNEL_TAG"
  printf 'Repository: %s\n' "$LINUX_KERNEL_REPOSITORY"
  printf 'Commit: %s\n' "$SOURCE_COMMIT"
  printf 'Signer: %s\n' "$LINUX_KERNEL_SIGNER"
  printf 'Signer fingerprint: %s\n' "$EXPECTED_FINGERPRINT"
  printf 'Verification: git verify-tag --raw (VALIDSIG fingerprint matched)\n'
} | tee "${OUT_DIR}/source-verification.txt"

if [[ ! -f "${SOURCE_DIR}/Makefile" ]]; then
  echo "error: verified kernel source is incomplete: ${SOURCE_DIR}" >&2
  exit 1
fi
if [[ ! -s "$FRAGMENT" ]]; then
  echo "error: missing kernel config fragment: $FRAGMENT" >&2
  exit 1
fi

echo "Configuring Linux ${LINUX_KERNEL_VERSION} for ${TARGET_ARCH} QEMU..."
make -C "$SOURCE_DIR" O="$OUT_DIR" "$DEFCONFIG"
ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  "${SOURCE_DIR}/scripts/kconfig/merge_config.sh" -m -O "$OUT_DIR" \
  "$OUT_DIR/.config" "$FRAGMENT"
make -C "$SOURCE_DIR" O="$OUT_DIR" olddefconfig

echo "Building $IMAGE_TARGET with $JOBS job(s)..."
make -C "$SOURCE_DIR" O="$OUT_DIR" -j"$JOBS" "$IMAGE_TARGET"

IMAGE="${OUT_DIR}/${IMAGE_RELATIVE_PATH}"
test -s "$IMAGE"
sha256sum "$IMAGE" | tee "${OUT_DIR}/${TARGET_ARCH}-kernel-image.sha256"

printf '\nVerified ${TARGET_ARCH} kernel build complete: %s\n' "$IMAGE"
