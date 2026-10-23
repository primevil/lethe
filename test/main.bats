#!/usr/bin/env bats
# End-to-end runs of lethe.sh against the fake OCI CLI and ssh

load test_helper

setup() {
  setup_mocks
}

@test "happy path: reuses the network, launches and reports the IP" {
  run bash "$LETHE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reusing existing free-vcn"* ]]
  [[ "$output" == *"AD-1"* ]]
  [[ "$output" == *"Canonical-Ubuntu-24.04-2026.10.01-0"* ]]
  [[ "$output" == *"Server configured successfully."* ]]
  [[ "$output" == *"Public IP:     203.0.113.10"* ]]
  [[ "$output" == *"should print ip=203.0.113.10"* ]]

  calls oci | grep -q -- 'compute instance launch .*--image-id ocid1.image.new .*--subnet-id ocid1.subnet.test'
  calls oci | grep -q -- 'route-table update --rt-id ocid1.rt.test .*ocid1.igw.test'
  refute_oci_call ' create '
  refute_oci_call '--shape-config'
}

@test "happy path: security list gets SSH plus the configured ports" {
  TCP_PORTS="443 8443" UDP_PORTS="51820" run bash "$LETHE"
  [ "$status" -eq 0 ]
  local rules
  rules=$(captured network_security-list_update.ingress.json)
  [ "$(jq -c '[.[] | select(.protocol=="6") | .tcpOptions.destinationPortRange.min]' <<< "$rules")" = "[22,443,8443]" ]
  [ "$(jq -c '[.[] | select(.protocol=="17") | .udpOptions.destinationPortRange.min]' <<< "$rules")" = "[51820]" ]
}

@test "happy path: authorized_keys and user-data are passed to the launch" {
  EXTRA_PUBKEY="ssh-ed25519 AAAAC3Nza you@laptop" SWAP_GB=3 run bash "$LETHE"
  [ "$status" -eq 0 ]
  [ "$(captured compute_instance_launch.authorized_keys)" = $'ssh-rsa AAAAexisting lethe@test\nssh-ed25519 AAAAC3Nza you@laptop' ]
  captured compute_instance_launch.user-data.sh | grep -qx 'SWAP_GB=3'
  captured compute_instance_launch.user-data.sh | bash -n
}

@test "creates VCN, gateway and subnet when they are missing" {
  respond network_vcn_list <<< '{"data":[]}'
  respond network_internet-gateway_list <<< '{"data":[]}'
  respond network_subnet_list <<< '{"data":[{"id":"old","lifecycle-state":"TERMINATED"}]}'
  respond network_vcn_create <<< '{"data":{"id":"ocid1.vcn.test"}}'
  respond network_internet-gateway_create <<< '{"data":{"id":"ocid1.igw.new"}}'
  respond network_subnet_create <<< '{"data":{"id":"ocid1.subnet.test"}}'
  run bash "$LETHE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created free-vcn"* ]]
  [[ "$output" == *"Created free-igw"* ]]
  [[ "$output" == *"Created free-subnet"* ]]
  calls oci | grep -q -- 'route-table update .*ocid1.igw.new'
  calls oci | grep -q -- 'subnet create .*--route-table-id ocid1.rt.test'
}

@test "existing instance: only updates the network and exits" {
  respond compute_instance_list <<< '{"data":[{"id":"ocid1.instance.old","lifecycle-state":"RUNNING"}]}'
  run bash "$LETHE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Instance already exists (IP: 203.0.113.10)"* ]]
  [[ "$output" == *"--instance-id ocid1.instance.old"* ]]
  calls oci | grep -q 'security-list update'
  refute_oci_call 'instance launch'
}

@test "terminated instance with the same name is ignored" {
  respond compute_instance_list <<< '{"data":[{"id":"ocid1.instance.old","lifecycle-state":"TERMINATED"}]}'
  run bash "$LETHE"
  [ "$status" -eq 0 ]
  calls oci | grep -q 'instance launch'
}

@test "A1.Flex adds the shape config" {
  SHAPE=VM.Standard.A1.Flex A1_OCPUS=4 A1_MEMORY_GB=24 run bash "$LETHE"
  [ "$status" -eq 0 ]
  calls oci | grep -qF -- '--shape-config {"ocpus":4,"memoryInGBs":24}'
}

@test "minimal image asks for the Minimal OS version" {
  UBUNTU_MINIMAL=true run bash "$LETHE"
  [ "$status" -eq 0 ]
  calls oci | grep -q -- '--operating-system-version 24.04 Minimal'
}

@test "fails when no AD offers the shape" {
  respond compute_shape_list <<< '{"data":[{"shape":"VM.Standard.E2.1.Micro"}]}'
  SHAPE=VM.Standard.A1.Flex run bash "$LETHE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Shape VM.Standard.A1.Flex is not offered"* ]]
  refute_oci_call 'instance launch'
}

@test "fails with the available versions when the image is missing" {
  respond_script compute_image_list << 'EOF'
if [[ "$*" == *--operating-system-version* ]]; then
  echo '{"data":[]}'
else
  echo '{"data":[{"operating-system-version":"22.04"},{"operating-system-version":"24.04 Minimal"},{"operating-system-version":"22.04"}]}'
fi
EOF
  run bash "$LETHE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'No Ubuntu "24.04" image'* ]]
  [[ "$output" == *"Available versions: 22.04, 24.04 Minimal"* ]]
}

@test "generates an SSH key when it is missing" {
  rm "$HOME/.ssh/oci_key" "$HOME/.ssh/oci_key.pub"
  run bash "$LETHE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated $HOME/.ssh/oci_key"* ]]
  [ "$(captured compute_instance_launch.authorized_keys)" = "ssh-rsa AAAAgenerated lethe@test" ]
}

@test "retries the launch on out of capacity" {
  export RETRY_DELAY=0
  respond_script compute_instance_launch << 'EOF'
if (( $(grep -c 'instance launch' "$MOCK_DIR/calls/oci") < 2 )); then
  echo "Out of host capacity." >&2; exit 1
fi
echo '{"data":{"id":"ocid1.instance.new"}}'
EOF
  run bash "$LETHE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Out of capacity (attempt 1/30)"* ]]
  [ "$(calls oci | grep -c 'instance launch')" -eq 2 ]
}

@test "warns when the bootstrap did not finish" {
  MOCK_BOOTSTRAP_LINE="E: Unable to locate package" run bash "$LETHE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: server setup may have failed"* ]]
}

@test "fails when SSH never comes up" {
  MOCK_SSH_RC=255 SSH_RETRIES=3 run bash "$LETHE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SSH not responding"* ]]
  [ "$(calls ssh | wc -l)" -eq 3 ]
}

@test "invalid settings stop the script before any OCI call" {
  TCP_PORTS="443;reboot" run bash "$LETHE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TCP_PORTS: invalid port"* ]]
  [ -z "$(calls oci)" ]
}

@test "COMPARTMENT_ID falls back to OCI_TENANCY" {
  unset COMPARTMENT_ID
  OCI_TENANCY=ocid1.tenancy.cloudshell run bash "$LETHE"
  [ "$status" -eq 0 ]
  calls oci | grep -q -- '-c ocid1.tenancy.cloudshell'
}

@test "removes its temporary directory" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  run bash "$LETHE"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "--help prints usage without touching OCI" {
  run bash "$LETHE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == "Usage: bash lethe.sh"* ]]
  [[ "$output" == *"UDP_PORTS"* ]]
  [ -z "$(calls oci)" ]
  [ ! -e "$LOGF" ]
}

@test "unknown options are rejected" {
  run bash "$LETHE" --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option: --force"* ]]
}

@test "COMPARTMENT_ID defaults to the tenancy in ~/.oci/config" {
  unset COMPARTMENT_ID
  mkdir -p "$HOME/.oci"
  printf '[DEFAULT]\ntenancy=ocid1.tenancy.oc1..fromconfig\n' > "$HOME/.oci/config"
  run bash "$LETHE"
  [ "$status" -eq 0 ]
  calls oci | grep -q -- 'iam compartment get --compartment-id ocid1.tenancy.oc1..fromconfig'
  calls oci | grep -q -- 'network vcn list -c ocid1.tenancy.oc1..fromconfig'
}

@test "without a compartment or OCI config it suggests oci setup bootstrap" {
  unset COMPARTMENT_ID
  run bash "$LETHE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'Run "oci setup bootstrap" once'* ]]
  [ -z "$(calls oci)" ]
}

@test "fails with a hint when the OCI config has no tenancy" {
  unset COMPARTMENT_ID
  mkdir -p "$HOME/.oci" && printf '[DEFAULT]\nregion=eu-frankfurt-1\n' > "$HOME/.oci/config"
  run bash "$LETHE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Set COMPARTMENT_ID"*"~/.oci/config"* ]]
  [ -z "$(calls oci)" ]
}

@test "authentication problems stop the script before any change" {
  respond_script iam_compartment_get <<< 'echo "ERROR: Could not find config file" >&2; exit 1'
  run bash "$LETHE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"oci setup bootstrap"* ]]
  [ "$(calls oci)" = "iam compartment get --compartment-id ocid1.tenancy.test" ]
}

@test "ssh never reads the script's stdin" {
  run bash "$LETHE"
  [ "$status" -eq 0 ]
  [ "$(calls ssh | grep -vc -- '^-n ')" -eq 0 ]
}
