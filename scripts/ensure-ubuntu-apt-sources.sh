#!/usr/bin/env bash
set -Eeuo pipefail

# GitHub-hosted Ubuntu images normally provide Ubuntu archive sources. Some
# runner images route those sources through a regional mirrorlist which can
# hang for hours when its HTTP mirror is unreachable. The installer workflow
# only needs official Ubuntu packages, so disable that mirrorlist source and
# use the signed HTTPS archive/security sources below.

if [[ "$EUID" -ne 0 ]]; then
  echo "error: run this helper with sudo." >&2
  exit 1
fi

if [[ ! -s /usr/share/keyrings/ubuntu-archive-keyring.gpg ]]; then
  echo "error: Ubuntu archive signing keyring is missing." >&2
  exit 1
fi

candidate_version() {
  apt-cache policy build-essential 2>/dev/null |
    awk '/Candidate:/ { print $2; exit }'
}

# Do not trust Candidate alone: apt-cache can report an installed package from
# /var/lib/dpkg/status even when no Ubuntu package index is configured. Require
# an actual package-index entry served from an Ubuntu archive host.
ubuntu_archive_candidate_available() {
  apt-cache policy build-essential 2>/dev/null |
    awk '
      /^[[:space:]]*[0-9]+[[:space:]]+https?:\/\/[^/]*\.ubuntu\.com\// {
        found = 1
      }
      END { exit !found }
    '
}

disable_unreliable_runner_mirrorlists() {
  local source_file
  local disabled_file
  local found=0

  # Ubuntu 24.04 GitHub runner images may use a Deb822 source whose URI points
  # at apt-mirrors.txt. Disable only source files using that mirrorlist; keep
  # unrelated vendor repositories intact. The official HTTPS sources are
  # installed below when no Ubuntu archive index is available.
  shopt -s nullglob
  for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$source_file" ]] || continue
    if grep -Eq 'mirror\+file:/etc/apt/apt-mirrors\.txt' "$source_file"; then
      disabled_file="${source_file}.disabled"
      mv -- "$source_file" "$disabled_file"
      printf 'Disabled unreliable Ubuntu mirrorlist source: %s\n' "$disabled_file"
      found=1
    fi
  done
  shopt -u nullglob

  if [[ "$found" -eq 0 ]]; then
    echo "No apt-mirrors.txt source found; retaining configured repositories."
  fi
}

# Bound both individual network operations and the complete apt-get update
# process. A stale/unreachable mirror must fail fast instead of consuming the
# six-hour Actions job timeout.
apt_update_with_retries() {
  local max_attempts="${1:-4}"
  local timeout_seconds="${AURA_APT_UPDATE_TIMEOUT_SECONDS:-120}"
  local attempt=1
  local status=0

  while (( attempt <= max_attempts )); do
    echo "Updating APT indexes (attempt ${attempt}/${max_attempts}, timeout ${timeout_seconds}s)..."
    if timeout --foreground --signal=TERM --kill-after=10s "${timeout_seconds}s" \
      apt-get \
        -o Acquire::Retries=1 \
        -o Acquire::http::Timeout=20 \
        -o Acquire::https::Timeout=20 \
        -o Acquire::ftp::Timeout=20 \
        -o Acquire::Queue-Mode=access \
        update; then
      return 0
    else
      status=$?
    fi

    if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
      echo "APT index update exceeded its ${timeout_seconds}s deadline." >&2
    fi

    if (( attempt < max_attempts )); then
      local delay=$((attempt * 5))
      echo "APT index update failed; retrying in ${delay}s." >&2
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done

  echo "error: apt-get update failed after ${max_attempts} bounded attempts." >&2
  return 1
}

disable_unreliable_runner_mirrorlists

update_status=0
if ! apt_update_with_retries 2; then
  update_status=1
fi

if [[ "$update_status" -ne 0 ]] || ! ubuntu_archive_candidate_available; then
  echo "Ubuntu archive package indexes are unavailable; adding official archive and security sources."

  cat > /etc/apt/sources.list.d/aura-ubuntu-noble.sources <<'EOF'
Types: deb
URIs: https://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
By-Hash: force

Types: deb
URIs: https://security.ubuntu.com/ubuntu
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
By-Hash: force
EOF

  apt_update_with_retries 4
fi

if ! ubuntu_archive_candidate_available; then
  echo "error: build-essential has no candidate backed by an Ubuntu archive index." >&2
  echo "APT sources visible to this runner:" >&2
  grep -RhsE '^(URIs:|Suites:|deb )' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null >&2 || true
  echo "apt-cache policy build-essential:" >&2
  apt-cache policy build-essential >&2 || true
  exit 1
fi

candidate="$(candidate_version)"
if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
  echo "error: build-essential has no installable candidate after enabling Ubuntu Noble sources." >&2
  exit 1
fi

printf 'Ubuntu package repositories are ready (build-essential candidate: %s).\n' "$candidate"
