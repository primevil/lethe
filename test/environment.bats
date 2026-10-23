#!/usr/bin/env bats
# Tests for the environment checks in lethe.sh: OS detection, install hints,
# missing commands, the OCI CLI config and --help
# Settings are plain globals read by the sourced functions:
# shellcheck disable=SC2034

load test_helper

setup() {
  setup_mocks
  load_lethe
}

# PATH with only the given commands (from the current PATH)
only_commands() {
  local dir="$BATS_TEST_TMPDIR/only-bin" cmd
  mkdir -p "$dir"
  for cmd in "$@"; do
    ln -sf "$(command -v "$cmd")" "$dir/$cmd"
  done
  echo "$dir"
}

# --- detect_os --------------------------------------------------------------

@test "detect_os recognises macOS" {
  LETHE_UNAME=Darwin run detect_os
  [ "$output" = "macos" ]
}

@test "detect_os maps Linux distributions to install families" {
  local distro expected
  while read -r distro expected; do
    LETHE_UNAME=Linux LETHE_OS_RELEASE="$BATS_TEST_DIRNAME/fixtures/os-release/$distro" run detect_os
    [ "$output" = "$expected" ] || { echo "$distro: got $output, want $expected"; return 1; }
  done << 'EOF'
ubuntu debian
debian debian
linuxmint debian
fedora fedora
ol oracle
rocky rhel
arch arch
endeavouros arch
opensuse unknown
EOF
}

@test "detect_os returns unknown without os-release" {
  LETHE_UNAME=Linux LETHE_OS_RELEASE=/nonexistent run detect_os
  [ "$output" = "unknown" ]
}

# --- install_commands -------------------------------------------------------

@test "install_commands installs pipx before using it" {
  local os
  for os in debian fedora arch; do
    run install_commands "$os"
    [[ "${lines[*]}" == *pipx* ]] || { echo "$os: no pipx"; return 1; }
    # the line that installs the pipx package comes before "pipx install"
    local pkg_line="" use_line="" i
    for i in "${!lines[@]}"; do
      [[ "${lines[$i]}" =~ (apt-get|dnf|pacman).*pipx ]] && pkg_line=$i
      [[ "${lines[$i]}" == "pipx install oci-cli" ]] && use_line=$i
    done
    [ -n "$pkg_line" ] && [ -n "$use_line" ] && [ "$pkg_line" -lt "$use_line" ] \
      || { echo "$os: pipx not installed first"; return 1; }
    [ "${lines[${#lines[@]}-1]}" = "pipx ensurepath" ]
  done
}

@test "install_commands covers jq and ssh on every known OS" {
  local os
  for os in macos debian fedora oracle rhel arch; do
    run install_commands "$os"
    [[ "$output" == *jq* && "$output" == *oci-cli* ]] || { echo "$os: $output"; return 1; }
    [[ "$os" == macos || "$output" == *openssh* ]] || { echo "$os: no openssh"; return 1; }
  done
}

@test "install_commands points unknown systems to the Oracle docs" {
  run install_commands unknown
  [[ "$output" == *"docs.oracle.com"*"cliinstall"* ]]
}

# --- check_deps -------------------------------------------------------------

@test "check_deps passes when everything is installed" {
  run check_deps
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check_deps lists missing commands with install commands for the OS" {
  local path
  path=$(only_commands ssh ssh-keygen)
  PATH="$path" LETHE_UNAME=Linux LETHE_OS_RELEASE="$BATS_TEST_DIRNAME/fixtures/os-release/ubuntu" run check_deps
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing: oci jq"* ]]
  [[ "$output" == *"sudo apt-get install -y jq openssh-client pipx"* ]]
  [[ "$output" == *"oci setup bootstrap"* ]]
  [[ "$output" != *"not in your PATH"* ]]
}

@test "check_deps shows brew on macOS" {
  local path
  path=$(only_commands oci ssh ssh-keygen)
  PATH="$path" LETHE_UNAME=Darwin run check_deps
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing: jq"* ]]
  [[ "$output" == *"brew install oci-cli jq"* ]]
}

@test "check_deps explains when oci is in ~/.local/bin but not in PATH" {
  local path
  path=$(only_commands jq ssh ssh-keygen)
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n' > "$HOME/.local/bin/oci"
  chmod +x "$HOME/.local/bin/oci"
  PATH="$path" LETHE_UNAME=Linux LETHE_OS_RELEASE="$BATS_TEST_DIRNAME/fixtures/os-release/fedora" run check_deps
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing: oci"* ]]
  [[ "$output" == *"~/.local/bin, which is not in your PATH"* ]]
  [[ "$output" == *"pipx ensurepath"* ]]
}

# --- config_tenancy ---------------------------------------------------------

@test "config_tenancy reads the DEFAULT profile" {
  mkdir -p "$HOME/.oci"
  cat > "$HOME/.oci/config" << 'EOF'
[DEFAULT]
user=ocid1.user.oc1..u
tenancy = ocid1.tenancy.oc1..default
region=eu-frankfurt-1

[work]
tenancy=ocid1.tenancy.oc1..work
EOF
  run config_tenancy
  [ "$output" = "ocid1.tenancy.oc1..default" ]
  OCI_CLI_PROFILE=work run config_tenancy
  [ "$output" = "ocid1.tenancy.oc1..work" ]
}

@test "config_tenancy falls back to DEFAULT and honours OCI_CLI_CONFIG_FILE" {
  cat > "$BATS_TEST_TMPDIR/cfg" << 'EOF'
[DEFAULT]
tenancy=ocid1.tenancy.oc1..default
[ session ]
region=eu-frankfurt-1
EOF
  OCI_CLI_CONFIG_FILE="$BATS_TEST_TMPDIR/cfg" OCI_CLI_PROFILE=session run config_tenancy
  [ "$output" = "ocid1.tenancy.oc1..default" ]
}

@test "config_tenancy prints nothing without a config" {
  run config_tenancy
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- check_auth -------------------------------------------------------------

@test "check_auth passes when the compartment is readable" {
  C=ocid1.tenancy.test
  run check_auth
  [ "$status" -eq 0 ]
  [[ "$(calls oci)" == "iam compartment get --compartment-id ocid1.tenancy.test" ]]
}

@test "check_auth suggests oci setup bootstrap without a config" {
  C=ocid1.tenancy.test
  respond_script iam_compartment_get <<< 'echo "ERROR: Could not find config file" >&2; exit 1'
  run check_auth
  [ "$status" -eq 1 ]
  [[ "$output" == *'Run "oci setup bootstrap" once'* ]]
  grep -q "Could not find config file" "$LOGF"
}

@test "check_auth shows the CLI error when the config is broken" {
  C=ocid1.tenancy.test
  mkdir -p "$HOME/.oci" && echo "[DEFAULT]" > "$HOME/.oci/config"
  respond_script iam_compartment_get <<< 'echo "ServiceError: NotAuthenticated" >&2; exit 1'
  run check_auth
  [ "$status" -eq 1 ]
  [[ "$output" == *"NotAuthenticated"* ]]
  [[ "$output" == *"cannot access compartment ocid1.tenancy.test (profile DEFAULT)"* ]]
}

@test "check_auth trusts OCI_CLI_AUTH (Cloud Shell) without a config file" {
  C=ocid1.tenancy.test
  respond_script iam_compartment_get <<< 'echo "NotAuthorizedOrNotFound" >&2; exit 1'
  OCI_CLI_AUTH=instance_obo_user run check_auth
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot access compartment"* ]]
  [[ "$output" != *"is not configured"* ]]
}
