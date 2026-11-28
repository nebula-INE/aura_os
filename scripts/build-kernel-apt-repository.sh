#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INPUT_PACKAGES="${1:-}"
OUTPUT_REPOSITORY="${2:-}"
PRIVATE_KEY_FILE="${AURA_APT_REPOSITORY_PRIVATE_KEY_FILE:-}"
PUBLIC_KEY_FILE="${AURA_APT_REPOSITORY_PUBLIC_KEY_FILE:-}"
EXPECTED_FINGERPRINT="${AURA_APT_REPOSITORY_FINGERPRINT:-}"
GNUPGHOME_DIR="${AURA_APT_GNUPGHOME:-}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -d "$INPUT_PACKAGES" ]] || fail "input kernel package directory is missing: $INPUT_PACKAGES"
[[ -n "$OUTPUT_REPOSITORY" ]] || fail "output repository directory is required"
[[ -s "$PRIVATE_KEY_FILE" ]] || fail "APT repository signing private key is missing"
[[ -s "$PUBLIC_KEY_FILE" ]] || fail "APT repository public key is missing"
[[ "$EXPECTED_FINGERPRINT" =~ ^[A-Fa-f0-9]{40,64}$ ]] || fail "a pinned APT repository fingerprint is required"

for cmd in apt-ftparchive dpkg-deb find sort gzip gpg sha256sum awk python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
done

GNUPGHOME_DIR="${GNUPGHOME_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/aura-apt-gnupg.XXXXXX")}"
mkdir -p "$GNUPGHOME_DIR"
chmod 0700 "$GNUPGHOME_DIR"
cleanup() {
  if [[ -n "${AURA_APT_GNUPGHOME:-}" ]]; then
    rm -f "$GNUPGHOME_DIR"/S.gpg-agent* 2>/dev/null || true
  else
    rm -rf "$GNUPGHOME_DIR"
  fi
}
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aura-apt-repository.XXXXXX")"
trap 'cleanup; rm -rf "$WORK_DIR"' EXIT

PASSPHRASE_FILE="$WORK_DIR/gpg-passphrase"
printf '%s' "${AURA_APT_REPOSITORY_SIGNING_KEY_PASSPHRASE:-}" > "$PASSPHRASE_FILE"
chmod 0600 "$PASSPHRASE_FILE"


public_fingerprint="$(gpg --batch --show-keys --with-colons "$PUBLIC_KEY_FILE" |
  awk -F: '$1 == "fpr" { print toupper($10); exit }')"
[[ -n "$public_fingerprint" ]] || fail "cannot read the APT repository public-key fingerprint"
[[ "$public_fingerprint" == "${EXPECTED_FINGERPRINT^^}" ]] ||
  fail "public-key fingerprint does not match the pinned APT fingerprint"

gpg --homedir "$GNUPGHOME_DIR" --batch --import "$PUBLIC_KEY_FILE" >/dev/null
gpg --homedir "$GNUPGHOME_DIR" --batch --import "$PRIVATE_KEY_FILE" >/dev/null
secret_fingerprint="$(gpg --homedir "$GNUPGHOME_DIR" --batch --with-colons --list-secret-keys |
  awk -F: '$1 == "fpr" { print toupper($10); exit }')"
[[ "$secret_fingerprint" == "${EXPECTED_FINGERPRINT^^}" ]] ||
  fail "private signing key does not match the pinned APT fingerprint"

declare -A image_packages=()
declare -A image_versions=()
declare -A meta_packages=()
declare -A meta_versions=()
declare -A meta_dependencies=()
found=0
while IFS= read -r -d '' package_file; do
  package_name="$(dpkg-deb -f "$package_file" Package)"
  package_version="$(dpkg-deb -f "$package_file" Version)"
  package_arch="$(dpkg-deb -f "$package_file" Architecture)"
  case "$package_name:$package_arch" in
    aura-kernel-image-*:amd64|aura-kernel-image-*:arm64|aura-kernel-image-*:riscv64)
      [[ -z "${image_packages[$package_arch]:-}" ]] ||
        fail "more than one kernel image package was supplied for $package_arch"
      image_packages[$package_arch]="$package_file"
      image_versions[$package_arch]="$package_version"
      ;;
    aura-kernel:all)
      dependencies="$(dpkg-deb -f "$package_file" Depends)"
      if [[ -z "${meta_packages[all]:-}" ]]; then
        meta_packages[all]="$package_file"
        meta_versions[all]="$package_version"
        meta_dependencies[all]="$dependencies"
      else
        [[ "${meta_versions[all]}" == "$package_version" &&
           "${meta_dependencies[all]}" == "$dependencies" ]] ||
          fail "architecture-independent aura-kernel packages do not match"
      fi
      ;;
    *)
      fail "unexpected package in repository input: $package_name ($package_arch)"
      ;;
  esac
  found=$((found + 1))
done < <(find "$INPUT_PACKAGES" -type f -name '*.deb' -print0 | sort -z)

[[ "$found" -eq 6 ]] || fail "expected exactly six kernel .deb inputs (three image and three meta packages), found $found"
image_package_name=""
for arch in amd64 arm64 riscv64; do
  [[ -n "${image_packages[$arch]:-}" ]] || fail "missing kernel image package for $arch"
  [[ -n "${meta_packages[all]:-}" ]] || fail "missing architecture-independent aura-kernel package"
  [[ "${image_versions[$arch]}" == "${meta_versions[all]}" ]] ||
    fail "kernel image and meta package versions differ for $arch"
  actual_package="$(dpkg-deb -f "${image_packages[$arch]}" Package)"
  if [[ -z "$image_package_name" ]]; then
    image_package_name="$actual_package"
  elif [[ "$actual_package" != "$image_package_name" ]]; then
    fail "kernel image package names differ between target architectures"
  fi
  expected_dependency="$actual_package (= ${image_versions[$arch]})"
  [[ "${meta_dependencies[all]}" == *"$expected_dependency"* ]] ||
    fail "aura-kernel meta package does not depend on the exact $arch image version"
done
[[ "${image_versions[amd64]}" == "${image_versions[arm64]}" &&
   "${image_versions[amd64]}" == "${image_versions[riscv64]}" ]] ||
  fail "kernel package versions differ between target architectures"

mkdir -p "$OUTPUT_REPOSITORY"
if [[ -s "$OUTPUT_REPOSITORY/KEY-FINGERPRINT.txt" ]]; then
  existing_fingerprint="$(awk 'NR == 1 { print $1 }' "$OUTPUT_REPOSITORY/KEY-FINGERPRINT.txt")"
  [[ "$existing_fingerprint" == "$public_fingerprint" ]] ||
    fail "APT repository key rotation is not automatic; existing and new fingerprints differ"
fi
POOL="$OUTPUT_REPOSITORY/pool/main"
DISTS="$OUTPUT_REPOSITORY/dists/stable"
mkdir -p "$POOL/a" "$DISTS"
for arch in amd64 arm64 riscv64; do
  package_file="${image_packages[$arch]}"
  package_name="$(dpkg-deb -f "$package_file" Package)"
  package_version="$(dpkg-deb -f "$package_file" Version)"
  destination="$POOL/a/$package_name"
  mkdir -p "$destination"
  install -m 0644 "$package_file" "$destination/${package_name}_${package_version}_${arch}.deb"
done
meta_name="$(dpkg-deb -f "${meta_packages[all]}" Package)"
meta_version="$(dpkg-deb -f "${meta_packages[all]}" Version)"
mkdir -p "$POOL/a/$meta_name"
install -m 0644 "${meta_packages[all]}" \
  "$POOL/a/$meta_name/${meta_name}_${meta_version}_all.deb"

for arch in amd64 arm64 riscv64; do
  index_dir="$DISTS/main/binary-$arch"
  mkdir -p "$index_dir"
  raw_index="$index_dir/Packages.raw"
  (
    cd "$OUTPUT_REPOSITORY"
    apt-ftparchive packages pool
  ) > "$raw_index"
  python3 - "$raw_index" "$index_dir/Packages" "$arch" <<'PY'
from pathlib import Path
import sys

source, destination, architecture = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
text = source.read_text(encoding="utf-8")
records = [record for record in text.split("\n\n") if record.strip()]
selected = []
for record in records:
    fields = {}
    for line in record.splitlines():
        if line and not line[0].isspace() and ": " in line:
            key, value = line.split(": ", 1)
            fields[key] = value
    if fields.get("Architecture") in (architecture, "all"):
        selected.append(record.strip() + "\n")
if not selected:
    raise SystemExit(f"no package records for {architecture}")
destination.write_text("\n".join(selected) + "\n", encoding="utf-8")
PY
  rm -f "$raw_index"
  gzip -n -9 -c "$index_dir/Packages" > "$index_dir/Packages.gz"
done

# apt-ftparchive's Release command walks existing Release metadata too.
# Remove old signatures/Release before generating a fresh index manifest and
# write the new Release outside the tree so it cannot hash itself.
rm -f "$DISTS/Release" "$DISTS/InRelease" "$DISTS/Release.gpg"
RELEASE_TEMP="$WORK_DIR/Release"
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="Aura OS" \
  -o APT::FTPArchive::Release::Label="Aura OS Kernel Repository" \
  -o APT::FTPArchive::Release::Suite="stable" \
  -o APT::FTPArchive::Release::Codename="stable" \
  -o APT::FTPArchive::Release::Architectures="amd64 arm64 riscv64" \
  -o APT::FTPArchive::Release::Components="main" \
  -o APT::FTPArchive::Release::Description="Signed Aura OS kernel updates" \
  release "$DISTS" > "$RELEASE_TEMP"
[[ -s "$RELEASE_TEMP" ]] || fail "apt-ftparchive did not create Release metadata"
install -m 0644 "$RELEASE_TEMP" "$DISTS/Release"

gpg --homedir "$GNUPGHOME_DIR" --batch --yes --pinentry-mode loopback \
  --passphrase-file "$PASSPHRASE_FILE" --local-user "$EXPECTED_FINGERPRINT" \
  --digest-algo SHA256 --clearsign --output "$DISTS/InRelease" "$DISTS/Release"
gpg --homedir "$GNUPGHOME_DIR" --batch --yes --pinentry-mode loopback \
  --passphrase-file "$PASSPHRASE_FILE" --local-user "$EXPECTED_FINGERPRINT" \
  --digest-algo SHA256 --armor --detach-sign --output "$DISTS/Release.gpg" "$DISTS/Release"

install -m 0644 "$PUBLIC_KEY_FILE" "$OUTPUT_REPOSITORY/aura-kernel-archive-key.asc"
printf '%s  %s\n' "$public_fingerprint" "Aura OS APT repository signing key" \
  > "$OUTPUT_REPOSITORY/KEY-FINGERPRINT.txt"

echo "Created signed Aura OS APT repository at $OUTPUT_REPOSITORY"
printf 'Kernel package version: %s\n' "${image_versions[amd64]}"
printf 'APT key fingerprint: %s\n' "$public_fingerprint"
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INPUT_PACKAGES="${1:-}"
OUTPUT_REPOSITORY="${2:-}"
PRIVATE_KEY_FILE="${AURA_APT_REPOSITORY_PRIVATE_KEY_FILE:-}"
PUBLIC_KEY_FILE="${AURA_APT_REPOSITORY_PUBLIC_KEY_FILE:-}"
EXPECTED_FINGERPRINT="${AURA_APT_REPOSITORY_FINGERPRINT:-}"
GNUPGHOME_DIR="${AURA_APT_GNUPGHOME:-}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -d "$INPUT_PACKAGES" ]] || fail "input kernel package directory is missing: $INPUT_PACKAGES"
[[ -n "$OUTPUT_REPOSITORY" ]] || fail "output repository directory is required"
[[ -s "$PRIVATE_KEY_FILE" ]] || fail "APT repository signing private key is missing"
[[ -s "$PUBLIC_KEY_FILE" ]] || fail "APT repository public key is missing"
[[ "$EXPECTED_FINGERPRINT" =~ ^[A-Fa-f0-9]{40,64}$ ]] || fail "a pinned APT repository fingerprint is required"

for cmd in apt-ftparchive dpkg-deb find sort gzip gpg sha256sum awk python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
done

GNUPGHOME_DIR="${GNUPGHOME_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/aura-apt-gnupg.XXXXXX")}"
mkdir -p "$GNUPGHOME_DIR"
chmod 0700 "$GNUPGHOME_DIR"
cleanup() {
  if [[ -n "${AURA_APT_GNUPGHOME:-}" ]]; then
    rm -f "$GNUPGHOME_DIR"/S.gpg-agent* 2>/dev/null || true
  else
    rm -rf "$GNUPGHOME_DIR"
  fi
}
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aura-apt-repository.XXXXXX")"
trap 'cleanup; rm -rf "$WORK_DIR"' EXIT

PASSPHRASE_FILE="$WORK_DIR/gpg-passphrase"
printf '%s' "${AURA_APT_REPOSITORY_SIGNING_KEY_PASSPHRASE:-}" > "$PASSPHRASE_FILE"
chmod 0600 "$PASSPHRASE_FILE"


public_fingerprint="$(gpg --batch --show-keys --with-colons "$PUBLIC_KEY_FILE" |
  awk -F: '$1 == "fpr" { print toupper($10); exit }')"
[[ -n "$public_fingerprint" ]] || fail "cannot read the APT repository public-key fingerprint"
[[ "$public_fingerprint" == "${EXPECTED_FINGERPRINT^^}" ]] ||
  fail "public-key fingerprint does not match the pinned APT fingerprint"

gpg --homedir "$GNUPGHOME_DIR" --batch --import "$PUBLIC_KEY_FILE" >/dev/null
gpg --homedir "$GNUPGHOME_DIR" --batch --import "$PRIVATE_KEY_FILE" >/dev/null
secret_fingerprint="$(gpg --homedir "$GNUPGHOME_DIR" --batch --with-colons --list-secret-keys |
  awk -F: '$1 == "fpr" { print toupper($10); exit }')"
[[ "$secret_fingerprint" == "${EXPECTED_FINGERPRINT^^}" ]] ||
  fail "private signing key does not match the pinned APT fingerprint"

declare -A image_packages=()
declare -A image_versions=()
declare -A meta_packages=()
declare -A meta_versions=()
declare -A meta_dependencies=()
found=0
while IFS= read -r -d '' package_file; do
  package_name="$(dpkg-deb -f "$package_file" Package)"
  package_version="$(dpkg-deb -f "$package_file" Version)"
  package_arch="$(dpkg-deb -f "$package_file" Architecture)"
  case "$package_name:$package_arch" in
    aura-kernel-image-*:amd64|aura-kernel-image-*:arm64|aura-kernel-image-*:riscv64)
      [[ -z "${image_packages[$package_arch]:-}" ]] ||
        fail "more than one kernel image package was supplied for $package_arch"
      image_packages[$package_arch]="$package_file"
      image_versions[$package_arch]="$package_version"
      ;;
    aura-kernel:all)
      dependencies="$(dpkg-deb -f "$package_file" Depends)"
      if [[ -z "${meta_packages[all]:-}" ]]; then
        meta_packages[all]="$package_file"
        meta_versions[all]="$package_version"
        meta_dependencies[all]="$dependencies"
      else
        [[ "${meta_versions[all]}" == "$package_version" &&
           "${meta_dependencies[all]}" == "$dependencies" ]] ||
          fail "architecture-independent aura-kernel packages do not match"
      fi
      ;;
    *)
      fail "unexpected package in repository input: $package_name ($package_arch)"
      ;;
  esac
  found=$((found + 1))
done < <(find "$INPUT_PACKAGES" -type f -name '*.deb' -print0 | sort -z)

[[ "$found" -eq 6 ]] || fail "expected exactly six kernel .deb inputs (three image and three meta packages), found $found"
image_package_name=""
for arch in amd64 arm64 riscv64; do
  [[ -n "${image_packages[$arch]:-}" ]] || fail "missing kernel image package for $arch"
  [[ -n "${meta_packages[all]:-}" ]] || fail "missing architecture-independent aura-kernel package"
  [[ "${image_versions[$arch]}" == "${meta_versions[all]}" ]] ||
    fail "kernel image and meta package versions differ for $arch"
  actual_package="$(dpkg-deb -f "${image_packages[$arch]}" Package)"
  if [[ -z "$image_package_name" ]]; then
    image_package_name="$actual_package"
  elif [[ "$actual_package" != "$image_package_name" ]]; then
    fail "kernel image package names differ between target architectures"
  fi
  expected_dependency="$actual_package (= ${image_versions[$arch]})"
  [[ "${meta_dependencies[all]}" == *"$expected_dependency"* ]] ||
    fail "aura-kernel meta package does not depend on the exact $arch image version"
done
[[ "${image_versions[amd64]}" == "${image_versions[arm64]}" &&
   "${image_versions[amd64]}" == "${image_versions[riscv64]}" ]] ||
  fail "kernel package versions differ between target architectures"

mkdir -p "$OUTPUT_REPOSITORY"
if [[ -s "$OUTPUT_REPOSITORY/KEY-FINGERPRINT.txt" ]]; then
  existing_fingerprint="$(awk 'NR == 1 { print $1 }' "$OUTPUT_REPOSITORY/KEY-FINGERPRINT.txt")"
  [[ "$existing_fingerprint" == "$public_fingerprint" ]] ||
    fail "APT repository key rotation is not automatic; existing and new fingerprints differ"
fi
POOL="$OUTPUT_REPOSITORY/pool/main"
DISTS="$OUTPUT_REPOSITORY/dists/stable"
mkdir -p "$POOL/a" "$DISTS"
for arch in amd64 arm64 riscv64; do
  package_file="${image_packages[$arch]}"
  package_name="$(dpkg-deb -f "$package_file" Package)"
  package_version="$(dpkg-deb -f "$package_file" Version)"
  destination="$POOL/a/$package_name"
  mkdir -p "$destination"
  install -m 0644 "$package_file" "$destination/${package_name}_${package_version}_${arch}.deb"
done
meta_name="$(dpkg-deb -f "${meta_packages[all]}" Package)"
meta_version="$(dpkg-deb -f "${meta_packages[all]}" Version)"
mkdir -p "$POOL/a/$meta_name"
install -m 0644 "${meta_packages[all]}" \
  "$POOL/a/$meta_name/${meta_name}_${meta_version}_all.deb"

for arch in amd64 arm64 riscv64; do
  index_dir="$DISTS/main/binary-$arch"
  mkdir -p "$index_dir"
  raw_index="$index_dir/Packages.raw"
  (
    cd "$OUTPUT_REPOSITORY"
    apt-ftparchive packages pool
  ) > "$raw_index"
  python3 - "$raw_index" "$index_dir/Packages" "$arch" <<'PY'
from pathlib import Path
import sys

source, destination, architecture = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
text = source.read_text(encoding="utf-8")
records = [record for record in text.split("\n\n") if record.strip()]
selected = []
for record in records:
    fields = {}
    for line in record.splitlines():
        if line and not line[0].isspace() and ": " in line:
            key, value = line.split(": ", 1)
            fields[key] = value
    if fields.get("Architecture") in (architecture, "all"):
        selected.append(record.strip() + "\n")
if not selected:
    raise SystemExit(f"no package records for {architecture}")
destination.write_text("\n".join(selected) + "\n", encoding="utf-8")
PY
  rm -f "$raw_index"
  gzip -n -9 -c "$index_dir/Packages" > "$index_dir/Packages.gz"
done

# apt-ftparchive's Release command walks existing Release metadata too.
# Remove old signatures/Release before generating a fresh index manifest and
# write the new Release outside the tree so it cannot hash itself.
rm -f "$DISTS/Release" "$DISTS/InRelease" "$DISTS/Release.gpg"
RELEASE_TEMP="$WORK_DIR/Release"
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="Aura OS" \
  -o APT::FTPArchive::Release::Label="Aura OS Kernel Repository" \
  -o APT::FTPArchive::Release::Suite="stable" \
  -o APT::FTPArchive::Release::Codename="stable" \
  -o APT::FTPArchive::Release::Architectures="amd64 arm64 riscv64" \
  -o APT::FTPArchive::Release::Components="main" \
  -o APT::FTPArchive::Release::Description="Signed Aura OS kernel updates" \
  release "$DISTS" > "$RELEASE_TEMP"
[[ -s "$RELEASE_TEMP" ]] || fail "apt-ftparchive did not create Release metadata"
install -m 0644 "$RELEASE_TEMP" "$DISTS/Release"

gpg --homedir "$GNUPGHOME_DIR" --batch --yes --pinentry-mode loopback \
  --passphrase-file "$PASSPHRASE_FILE" --local-user "$EXPECTED_FINGERPRINT" \
  --digest-algo SHA256 --clearsign --output "$DISTS/InRelease" "$DISTS/Release"
gpg --homedir "$GNUPGHOME_DIR" --batch --yes --pinentry-mode loopback \
  --passphrase-file "$PASSPHRASE_FILE" --local-user "$EXPECTED_FINGERPRINT" \
  --digest-algo SHA256 --armor --detach-sign --output "$DISTS/Release.gpg" "$DISTS/Release"

install -m 0644 "$PUBLIC_KEY_FILE" "$OUTPUT_REPOSITORY/aura-kernel-archive-key.asc"
printf '%s  %s\n' "$public_fingerprint" "Aura OS APT repository signing key" \
  > "$OUTPUT_REPOSITORY/KEY-FINGERPRINT.txt"

echo "Created signed Aura OS APT repository at $OUTPUT_REPOSITORY"
printf 'Kernel package version: %s\n' "${image_versions[amd64]}"
printf 'APT key fingerprint: %s\n' "$public_fingerprint"
