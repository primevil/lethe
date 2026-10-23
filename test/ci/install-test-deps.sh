#!/bin/sh
# Installs what the bats tests need in a CI container
set -eu
# shellcheck disable=SC1091
. /etc/os-release
case "$ID" in
  debian|ubuntu)
    apt-get update -qq
    apt-get install -y -qq bats jq >/dev/null ;;
  fedora)
    dnf install -y -q bats jq diffutils gawk ;;
  ol)
    dnf install -y -q oracle-epel-release-el9
    dnf install -y -q bats jq diffutils gawk ;;
  rocky|almalinux)
    dnf install -y -q epel-release
    dnf install -y -q bats jq diffutils gawk ;;
  arch)
    grep -qx 'DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
    pacman -Sy --noconfirm --needed bats jq diffutils gawk >/dev/null ;;
  *)
    echo "unsupported: $ID" >&2; exit 1 ;;
esac
