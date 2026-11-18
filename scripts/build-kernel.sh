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
ARCH="${ARCH:-x86}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in git gpg curl awk grep make perl tr; do
  require_command "$cmd"
done

if [[ "${ARCH}" != "x86" ]]; then
  echo "error: this initial script supports ARCH=x86 only; RV64GC and AArch64 are planned next." >&2
  exit 2
fi

mkdir -p "${WORK_DIR}" "${OUT_DIR}" "${KEYRING_DIR}"
chmod 700 "${KEYRING_DIR}"
export GNUPGHOME="${KEYRING_DIR}"
EXPECTED_FINGERPRINT="$(printf '%s' "${LINUX_KERNEL_SIGNING_KEY_FINGERPRINT}" | tr '[:lower:]' '[:upper:]')"

echo "Importing the Linux stable maintainer key through kernel.org WKD..."
if ! gpg --batch --locate-keys "${LINUX_KERNEL_SIGNER}"; then
  echo "warning: kernel.org WKD is unavailable; trying fingerprint-addressed HTTPS key endpoints." >&2
  KEY_FILE="${WORK_DIR}/linux-stable-maintainer-key.asc"
  fetch_key() {
    local url="$1"
    if curl --fail --location --retry 2 --connect-timeout 10 --max-time 45 \
      --output "${KEY_FILE}" "${url}" &&
      gpg --batch --import "${KEY_FILE}"; then
      return 0
    fi
    return 1
  }
  if ! fetch_key "https://keys.openpgp.org/vks/v1/by-fingerprint/${EXPECTED_FINGERPRINT}" &&
    ! fetch_key "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${EXPECTED_FINGERPRINT}"; then
    echo "error: unable to retrieve the pinned signing key from WKD or HTTPS keyservers." >&2
    exit 1
  fi
fi

if ! gpg --batch --with-colons --list-keys "${LINUX_KERNEL_SIGNER}" |
  awk -F: -v expected="${EXPECTED_FINGERPRINT}" '$1 == "fpr" && toupper($10) == expected { found = 1 } END { exit !found }'; then
  echo "error: the retrieved key does not match the pinned kernel.org fingerprint." >&2
  echo "Expected: ${EXPECTED_FINGERPRINT}" >&2
  exit 1
fi

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  rm -rf "${SOURCE_DIR}"
  echo "Cloning upstream Linux tag ${LINUX_KERNEL_TAG}..."
  git clone --depth 1 --single-branch --branch "${LINUX_KERNEL_TAG}" \
    "${LINUX_KERNEL_REPOSITORY}" "${SOURCE_DIR}"
else
  origin="$(git -C "${SOURCE_DIR}" remote get-url origin)"
  if [[ "${origin}" != "${LINUX_KERNEL_REPOSITORY}" ]]; then
    echo "error: cached kernel source has an unexpected origin: ${origin}" >&2
    exit 1
  fi
  git -C "${SOURCE_DIR}" fetch --depth 1 origin \
    "refs/tags/${LINUX_KERNEL_TAG}:refs/tags/${LINUX_KERNEL_TAG}"
fi

echo "Verifying signed upstream tag ${LINUX_KERNEL_TAG}..."
if ! verify_output="$(git -C "${SOURCE_DIR}" verify-tag --raw "${LINUX_KERNEL_TAG}" 2>&1)"; then
  printf '%s\n' "$verify_output" >&2
  echo "error: upstream Linux tag signature verification failed." >&2
  exit 1
fi
printf '%s\n' "$verify_output"
if ! grep -Fq "[GNUPG:] VALIDSIG ${EXPECTED_FINGERPRINT}" <<<"$verify_output"; then
  echo "error: the signed tag was not made by the pinned stable maintainer key." >&2
  exit 1
fi

git -C "${SOURCE_DIR}" checkout --detach --force "${LINUX_KERNEL_TAG}"
git -C "${SOURCE_DIR}" clean -fdx
SOURCE_COMMIT="$(git -C "${SOURCE_DIR}" rev-parse "${LINUX_KERNEL_TAG}^{commit}")"
CURRENT_COMMIT="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
if [[ "$SOURCE_COMMIT" != "$CURRENT_COMMIT" ]]; then
  echo "error: checked out source does not match the verified tag." >&2
  exit 1
fi

{
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

echo "Configuring Linux ${LINUX_KERNEL_VERSION} for x86-64 QEMU..."
make -C "${SOURCE_DIR}" O="${OUT_DIR}" ARCH=x86 x86_64_defconfig
"${SOURCE_DIR}/scripts/kconfig/merge_config.sh" -m -O "${OUT_DIR}" \
  "${OUT_DIR}/.config" "${ROOT_DIR}/kernel/configs/x86_64_qemu.fragment"
make -C "${SOURCE_DIR}" O="${OUT_DIR}" ARCH=x86 olddefconfig

echo "Building bzImage with ${JOBS} job(s)..."
make -C "${SOURCE_DIR}" O="${OUT_DIR}" ARCH=x86 -j"${JOBS}" bzImage

IMAGE="${OUT_DIR}/arch/x86/boot/bzImage"
test -s "$IMAGE"
sha256sum "$IMAGE" | tee "${OUT_DIR}/bzImage.sha256"

printf '\nVerified kernel build complete: %s\n' "$IMAGE"
