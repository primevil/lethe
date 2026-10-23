# Shared setup for the bats tests.

LETHE="$BATS_TEST_DIRNAME/../lethe.sh"

# Puts the fake oci / ssh / ssh-keygen / sleep first in PATH, isolates HOME
# and loads the happy-path OCI responses from test/fixtures/oci.
setup_mocks() {
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock"
  mkdir -p "$MOCK_DIR/bin" "$MOCK_DIR/responses" "$MOCK_DIR/calls" "$MOCK_DIR/captured"
  local m
  for m in oci ssh ssh-keygen sleep; do
    ln -s "$BATS_TEST_DIRNAME/mocks/$m" "$MOCK_DIR/bin/$m"
  done
  cp "$BATS_TEST_DIRNAME"/fixtures/oci/*.json "$MOCK_DIR/responses/"
  use_gnu_sed
  export PATH="$MOCK_DIR/bin:$PATH"

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  echo "FAKE PRIVATE KEY" > "$HOME/.ssh/oci_key"
  echo "ssh-rsa AAAAexisting lethe@test" > "$HOME/.ssh/oci_key.pub"

  export COMPARTMENT_ID="ocid1.tenancy.test"
  export LOGF="$BATS_TEST_TMPDIR/lethe.log"
  unset OCI_TENANCY SHAPE TCP_PORTS UDP_PORTS EXTRA_PUBKEY UBUNTU_MINIMAL UBUNTU_VERSION \
        SWAP_GB A1_OCPUS A1_MEMORY_GB LAUNCH_RETRIES RETRY_DELAY SSH_RETRIES SSH_RETRY_DELAY \
        INSTANCE_NAME SSH_KEY OCI_CLI_PROFILE OCI_CLI_AUTH OCI_CLI_CONFIG_FILE LETHE_UNAME LETHE_OS_RELEASE
}

# patch_iptables_rules runs on Ubuntu and needs GNU sed (gsed on macOS)
use_gnu_sed() {
  if ! sed --version >/dev/null 2>&1; then
    command -v gsed >/dev/null || skip "GNU sed is required (brew install gnu-sed)"
    mkdir -p "$MOCK_DIR/bin"
    ln -sf "$(command -v gsed)" "$MOCK_DIR/bin/sed"
  fi
}

# Loads lethe.sh functions without running main
load_lethe() {
  # shellcheck source=lethe.sh
  LETHE_LIB_ONLY=1 source "$LETHE"
}

# respond KEY < json   - fixed OCI response for "oci A B C ..." (KEY = A_B_C)
respond() { cat > "$MOCK_DIR/responses/$1.json"; }

# respond_script KEY < script   - dynamic OCI response, gets the call's args
respond_script() {
  rm -f "$MOCK_DIR/responses/$1.json"
  cat > "$MOCK_DIR/responses/$1.sh"
}

calls() { cat "$MOCK_DIR/calls/$1" 2>/dev/null || true; }
captured() { cat "$MOCK_DIR/captured/$1"; }

# refute_oci_call PATTERN   - fails if any oci call matches the grep pattern
refute_oci_call() {
  if calls oci | grep -q -- "$1"; then
    echo "unexpected oci call matching: $1" >&2
    calls oci | grep -- "$1" >&2
    return 1
  fi
}
