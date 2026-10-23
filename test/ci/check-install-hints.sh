#!/usr/bin/env bash
# Runs the install commands lethe.sh suggests for this Linux distribution (in a
# fresh CI container, as root) and checks that oci, jq and ssh then work.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Containers run as root without sudo
if ! command -v sudo >/dev/null; then
  printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/sudo
  chmod +x /usr/local/bin/sudo
fi
# Arch images ship without a package database; pacman's sandbox does not
# work in every container runtime
if command -v pacman >/dev/null; then
  sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
  pacman -Sy --noconfirm >/dev/null
fi

# shellcheck source=lethe.sh
LETHE_LIB_ONLY=1 source lethe.sh
os=$(detect_os)
echo "Detected: $os"
[[ "$os" != unknown ]] || { echo "unknown OS" >&2; exit 1; }

# From a file, not stdin: apt-get / dpkg would read the remaining commands
install_commands "$os" > /tmp/install.sh
cat /tmp/install.sh
bash -euxo pipefail /tmp/install.sh < /dev/null

export PATH="$HOME/.local/bin:$PATH"
oci --version
jq --version
ssh -V
ssh-keygen -t ed25519 -N "" -q -f "$(mktemp -d)/k"
