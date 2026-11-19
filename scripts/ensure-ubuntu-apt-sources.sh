#!/usr/bin/env bash
set -Eeuo pipefail

# GitHub-hosted Ubuntu images normally provide Ubuntu archive sources. If the
# runner image exposes only extra vendor feeds (for example, packages.microsoft.com),
# restore the official signed Noble sources before installing build dependencies.

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

update_status=0
if ! apt-get update -o Acquire::Retries=3; then
  update_status=1
fi

candidate="$(candidate_version)"
if [[ "$update_status" -ne 0 || -z "$candidate" || "$candidate" == "(none)" ]]; then
  echo "Ubuntu Noble package candidates are unavailable; adding official archive and security sources."

  cat > /etc/apt/sources.list.d/aura-ubuntu-noble.sources <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

  apt-get update -o Acquire::Retries=3
  candidate="$(candidate_version)"
fi

if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
  echo "error: build-essential still has no candidate after enabling official Ubuntu Noble sources." >&2
  echo "APT sources visible to this runner:" >&2
  grep -RhsE '^(URIs:|Suites:|deb )' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null >&2 || true
  exit 1
fi

printf 'Ubuntu package repositories are ready (build-essential candidate: %s).\n' "$candidate"
