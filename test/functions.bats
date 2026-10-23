#!/usr/bin/env bats
# Unit tests for the helper functions in lethe.sh
# Settings are plain globals read by the sourced functions:
# shellcheck disable=SC2034

load test_helper

setup() {
  setup_mocks
  load_lethe
}

# --- pick_available / pick_live_instance -----------------------------------

@test "pick_available returns the first AVAILABLE id" {
  run pick_available <<< '{"data":[
    {"id":"a","lifecycle-state":"TERMINATED"},
    {"id":"b","lifecycle-state":"AVAILABLE"},
    {"id":"c","lifecycle-state":"AVAILABLE"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "b" ]
}

@test "pick_available prints nothing for empty or missing data" {
  run pick_available <<< '{"data":[]}'
  [ -z "$output" ]
  run pick_available <<< '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pick_live_instance skips terminated instances" {
  run pick_live_instance <<< '{"data":[
    {"id":"dead","lifecycle-state":"TERMINATED"},
    {"id":"dying","lifecycle-state":"TERMINATING"},
    {"id":"off","lifecycle-state":"STOPPED"}]}'
  [ "$output" = "off" ]
}

@test "pick_live_instance prints nothing when only terminated instances exist" {
  run pick_live_instance <<< '{"data":[{"id":"dead","lifecycle-state":"TERMINATED"}]}'
  [ -z "$output" ]
}

# --- validation -------------------------------------------------------------

@test "validate_settings accepts the defaults" {
  run validate_settings
  [ "$status" -eq 0 ]
}

@test "validate_settings requires a compartment" {
  COMPARTMENT_ID=""
  run validate_settings
  [ "$status" -eq 1 ]
  [[ "$output" == *"COMPARTMENT_ID"* ]]
}

@test "validate_ports accepts several ports and extra whitespace" {
  run validate_ports TCP_PORTS "  443   8443 1 65535 "
  [ "$status" -eq 0 ]
}

@test "validate_ports accepts an empty list" {
  run validate_ports UDP_PORTS ""
  [ "$status" -eq 0 ]
}

@test "validate_ports rejects bad values" {
  local bad
  # shellcheck disable=SC2016
  for bad in 0 65536 abc 44x -1 0443 '443,8443' '$(id)'; do
    run validate_ports TCP_PORTS "$bad"
    [ "$status" -eq 1 ] || { echo "accepted: $bad"; return 1; }
    [[ "$output" == *"TCP_PORTS: invalid port"* ]]
  done
}

@test "validate_settings rejects non-numeric numeric settings" {
  local v
  for v in SWAP_GB A1_OCPUS A1_MEMORY_GB LAUNCH_RETRIES RETRY_DELAY SSH_RETRIES SSH_RETRY_DELAY; do
    (
      printf -v "$v" '%s' "2x"
      run validate_settings
      [ "$status" -eq 1 ] && [[ "$output" == *"$v must be a non-negative integer"* ]]
    ) || { echo "not rejected: $v"; return 1; }
  done
}

@test "validate_settings requires at least one launch attempt" {
  LAUNCH_RETRIES=0
  run validate_settings
  [ "$status" -eq 1 ]
  [[ "$output" == *"LAUNCH_RETRIES must be at least 1"* ]]
}

@test "validate_settings allows SWAP_GB=0" {
  SWAP_GB=0
  run validate_settings
  [ "$status" -eq 0 ]
}

@test "validate_settings rejects zero OCPUs for a Flex shape only" {
  A1_OCPUS=0
  run validate_settings
  [ "$status" -eq 0 ]
  SHAPE=VM.Standard.A1.Flex
  run validate_settings
  [ "$status" -eq 1 ]
}

@test "validate_settings checks UBUNTU_MINIMAL and UBUNTU_VERSION" {
  UBUNTU_MINIMAL=yes
  run validate_settings
  [ "$status" -eq 1 ]
  UBUNTU_MINIMAL=true UBUNTU_VERSION=noble
  run validate_settings
  [ "$status" -eq 1 ]
  UBUNTU_VERSION=22.04
  run validate_settings
  [ "$status" -eq 0 ]
}

@test "validate_settings rejects unsafe instance names" {
  INSTANCE_NAME='vpn"; rm -rf /'
  run validate_settings
  [ "$status" -eq 1 ]
}

@test "validate_settings accepts common SSH public keys" {
  local key
  for key in \
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq you@laptop" \
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ==" \
    "ecdsa-sha2-nistp256 AAAAE2VjZHNh= me" \
    "sk-ssh-ed25519@openssh.com AAAAGnNr yubikey"; do
    EXTRA_PUBKEY="$key"
    run validate_settings
    [ "$status" -eq 0 ] || { echo "rejected: $key"; return 1; }
  done
}

@test "validate_settings rejects things that are not a public key" {
  local key
  for key in \
    "AAAAC3NzaC1lZDI1NTE5" \
    "-----BEGIN OPENSSH PRIVATE KEY-----" \
    "ssh-ed25519" \
    $'ssh-ed25519 AAAA one\nssh-ed25519 AAAA two'; do
    EXTRA_PUBKEY="$key"
    run validate_settings
    [ "$status" -eq 1 ] || { echo "accepted: $key"; return 1; }
    [[ "$output" == *"EXTRA_PUBKEY"* ]]
  done
}

# --- ingress_rules ----------------------------------------------------------

@test "ingress_rules always opens SSH and the ICMP rules" {
  run ingress_rules "" "" "10.0.0.0/16"
  [ "$status" -eq 0 ]
  [ "$(jq length <<< "$output")" -eq 3 ]
  [ "$(jq -c '.[0]' <<< "$output")" = '{"source":"0.0.0.0/0","protocol":"6","tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}' ]
  [ "$(jq -r '.[2].source' <<< "$output")" = "10.0.0.0/16" ]
}

@test "ingress_rules de-duplicates ports and does not repeat 22" {
  run ingress_rules "443 22  443 8443" "443 51820" "10.0.0.0/16"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.[] | select(.protocol=="6") | .tcpOptions.destinationPortRange.min]' <<< "$output")" = "[22,443,8443]" ]
  [ "$(jq -c '[.[] | select(.protocol=="17") | .udpOptions.destinationPortRange.min]' <<< "$output")" = "[443,51820]" ]
}

@test "ingress_rules accepts tabs and newlines between ports" {
  run ingress_rules $'443\t8443\n9443' "" "10.0.0.0/16"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.[] | select(.protocol=="6") | .tcpOptions.destinationPortRange.min]' <<< "$output")" = "[22,443,8443,9443]" ]
}

# --- patch_iptables_rules ---------------------------------------------------

@test "patch_iptables_rules opens ports before the INPUT REJECT and drops the FORWARD REJECT" {
  local rules="$BATS_TEST_TMPDIR/rules.v4"
  cp "$BATS_TEST_DIRNAME/fixtures/rules.v4" "$rules"
  patch_iptables_rules "$rules" "443 8443" "443"

  run grep -c -- '-A FORWARD -j REJECT' "$rules"
  [ "$output" = 0 ]
  local reject tcp443 tcp8443 udp443
  reject=$(grep -n -- '^-A INPUT -j REJECT' "$rules" | cut -d: -f1)
  tcp443=$(grep -n -- '-p tcp -m state --state NEW -m tcp --dport 443 -j ACCEPT' "$rules" | cut -d: -f1)
  tcp8443=$(grep -n -- '--dport 8443 -j ACCEPT' "$rules" | cut -d: -f1)
  udp443=$(grep -n -- '-p udp -m udp --dport 443 -j ACCEPT' "$rules" | cut -d: -f1)
  [ -n "$tcp443" ] && [ -n "$tcp8443" ] && [ -n "$udp443" ]
  [ "$tcp443" -lt "$reject" ] && [ "$tcp8443" -lt "$reject" ] && [ "$udp443" -lt "$reject" ]
}

@test "patch_iptables_rules is idempotent" {
  local rules="$BATS_TEST_TMPDIR/rules.v4"
  cp "$BATS_TEST_DIRNAME/fixtures/rules.v4" "$rules"
  patch_iptables_rules "$rules" "22 443" "443"
  cp "$rules" "$BATS_TEST_TMPDIR/once"
  patch_iptables_rules "$rules" "22 443" "443"
  diff "$BATS_TEST_TMPDIR/once" "$rules"
  [ "$(grep -c -- '--dport 22 -j ACCEPT' "$rules")" -eq 1 ]
}

@test "patch_iptables_rules does not mistake port 44 for 443" {
  local rules="$BATS_TEST_TMPDIR/rules.v4"
  cp "$BATS_TEST_DIRNAME/fixtures/rules.v4" "$rules"
  patch_iptables_rules "$rules" "443" ""
  patch_iptables_rules "$rules" "44" ""
  grep -q -- '-m tcp --dport 44 -j ACCEPT' "$rules"
}

# --- render_user_data -------------------------------------------------------

@test "render_user_data is valid bash and embeds the settings" {
  SWAP_GB=4 TCP_PORTS="443 8443" UDP_PORTS=""
  run render_user_data
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "#!/bin/bash" ]
  bash -n <<< "$output"
  [[ "$output" == *"SWAP_GB=4"* ]]
  [[ "$output" == *'TCP_PORTS=443\ 8443'* ]]
  [[ "$output" == *"patch_iptables_rules ()"* ]]
  [[ "$output" == *'echo "BOOTSTRAP OK"'* ]]
}

@test "render_user_data settings evaluate back to the same values" {
  SWAP_GB=0 TCP_PORTS="443 8443" UDP_PORTS="443"
  render_user_data | sed -n '2,4p' > "$BATS_TEST_TMPDIR/vars.sh"
  run bash -c "source '$BATS_TEST_TMPDIR/vars.sh'; printf '%s|%s|%s' \"\$SWAP_GB\" \"\$TCP_PORTS\" \"\$UDP_PORTS\""
  [ "$output" = "0|443 8443|443" ]
}

# --- find_availability_domain / launch_with_retry ---------------------------

@test "find_availability_domain returns the first AD offering the shape" {
  C=ocid1.tenancy.test SHAPE=VM.Standard.A1.Flex
  respond_script compute_shape_list << 'EOF'
if [[ "$*" == *"AD-1"* ]]; then
  echo '{"data":[{"shape":"VM.Standard.E2.1.Micro"}]}'
else
  echo '{"data":[{"shape":"VM.Standard.A1.Flex"}]}'
fi
EOF
  run find_availability_domain
  [ "$output" = "AD-2" ]
}

@test "find_availability_domain prints nothing when no AD offers the shape" {
  C=ocid1.tenancy.test SHAPE=VM.Standard.E5.Flex
  run find_availability_domain
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "launch_with_retry retries on out of capacity" {
  WORKDIR="$BATS_TEST_TMPDIR" LAUNCH_RETRIES=5 RETRY_DELAY=7
  respond_script compute_instance_launch << 'EOF'
n=$(grep -c 'instance launch' "$MOCK_DIR/calls/oci")
if (( n < 3 )); then
  echo 'ServiceError: {"code": "InternalError", "message": "Out of host capacity."}' >&2
  exit 1
fi
echo '{"data":{"id":"ocid1.instance.third"}}'
EOF
  run launch_with_retry compute instance launch --shape X
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "ocid1.instance.third" ]
  [ "$(calls sleep)" = $'7\n7' ]
}

@test "launch_with_retry gives up after LAUNCH_RETRIES attempts" {
  WORKDIR="$BATS_TEST_TMPDIR" LAUNCH_RETRIES=3
  respond_script compute_instance_launch <<< 'echo "Out of host capacity." >&2; exit 1'
  run launch_with_retry compute instance launch
  [ "$status" -eq 1 ]
  [[ "$output" == *"Still out of capacity after 3 attempts"* ]]
  [ "$(calls oci | wc -l)" -eq 3 ]
}

@test "launch_with_retry fails at once on other errors" {
  WORKDIR="$BATS_TEST_TMPDIR" LAUNCH_RETRIES=5
  respond_script compute_instance_launch <<< 'echo "NotAuthorizedOrNotFound" >&2; exit 1'
  run launch_with_retry compute instance launch
  [ "$status" -eq 1 ]
  [[ "$output" == *"NotAuthorizedOrNotFound"* ]]
  [[ "$output" == *"Failed to launch the instance"* ]]
  [ "$(calls oci | wc -l)" -eq 1 ]
  [ -z "$(calls sleep)" ]
}
