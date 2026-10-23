#!/usr/bin/env bash
# ============================================================================
#  lethe.sh
#  Copyright (c) 2026, primevil. Licensed under the BSD 3-Clause License.
#
#  Creates an Always Free Ubuntu VM on Oracle Cloud, ready for installing
#  Amnezia VPN (Xray) from the Amnezia client.
#
#  Run in OCI Cloud Shell:   bash lethe.sh
#
#  What it does:
#   1. Creates (or reuses) a VCN, internet gateway, route and public subnet.
#   2. Opens ports in the security list (SSH 22 + TCP_PORTS / UDP_PORTS).
#      NOTE: the ingress rules of that security list are fully overwritten.
#   3. Finds an availability domain where the chosen shape is offered.
#   4. Picks the newest Ubuntu image compatible with the shape.
#   5. Launches the instance (retrying on "Out of host capacity").
#   6. On first boot (cloud-init) the server:
#        - adds swap,
#        - installs openssh-sftp-server (without it Amnezia uploads empty
#          files), docker.io, docker-buildx, iptables-persistent,
#        - removes the blocking REJECT rule from the FORWARD chain,
#        - opens the ports in iptables.
#
#  Safe to re-run: if the instance already exists, the script only updates
#  the network and port rules.
# ============================================================================

# ------------------------------ SETTINGS -----------------------------------
# Every value can be overridden with an environment variable, e.g.:
#   UDP_PORTS="443 51820" bash lethe.sh

COMPARTMENT_ID="${COMPARTMENT_ID:-${OCI_TENANCY:-}}"
INSTANCE_NAME="${INSTANCE_NAME:-ubuntu-free}"

# VM.Standard.E2.1.Micro (x86, 1 GB RAM) or VM.Standard.A1.Flex (ARM)
SHAPE="${SHAPE:-VM.Standard.E2.1.Micro}"
A1_OCPUS="${A1_OCPUS:-2}"
A1_MEMORY_GB="${A1_MEMORY_GB:-12}"

# Full (non-minimal) 24.04 is the most reliable choice for Amnezia
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
UBUNTU_MINIMAL="${UBUNTU_MINIMAL:-false}"

# Xray ports (SSH 22 is always opened)
TCP_PORTS="${TCP_PORTS:-443}"
UDP_PORTS="${UDP_PORTS:-443}"

# 0 disables the swap file
SWAP_GB="${SWAP_GB:-2}"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/oci_key}"
# Optional: your own public key from your computer (the whole "ssh-ed25519 ..." line)
EXTRA_PUBKEY="${EXTRA_PUBKEY:-}"

VCN_NAME="${VCN_NAME:-free-vcn}"
IGW_NAME="${IGW_NAME:-free-igw}"
SUBNET_NAME="${SUBNET_NAME:-free-subnet}"
VCN_CIDR="${VCN_CIDR:-10.0.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.0.0.0/24}"

# Retries when the region is out of capacity
LAUNCH_RETRIES="${LAUNCH_RETRIES:-30}"
RETRY_DELAY="${RETRY_DELAY:-60}"

# Waiting for SSH after launch: attempts x delay (default 10 minutes)
SSH_RETRIES="${SSH_RETRIES:-60}"
SSH_RETRY_DELAY="${SSH_RETRY_DELAY:-10}"
# ---------------------------------------------------------------------------

LOGF="${LOGF:-$HOME/lethe.log}"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# First AVAILABLE object from a "list" response
pick_available() { jq -r '[.data[]? | select(."lifecycle-state"=="AVAILABLE")] | .[0].id // empty'; }

# First instance from a "list" response that is not terminated / terminating
pick_live_instance() {
  jq -r '[.data[]? | select(."lifecycle-state" as $s
            | ["PROVISIONING","STARTING","RUNNING","STOPPING","STOPPED"] | index($s))]
         | .[0].id // empty'
}

usage() {
  cat << 'EOF'
Usage: bash lethe.sh [--help]

Creates an Always Free Ubuntu VM on Oracle Cloud, ready for installing
Amnezia VPN (Xray) from the Amnezia client. Runs in OCI Cloud Shell, or on
macOS / Linux with the OCI CLI and jq installed and configured.

Settings are environment variables, e.g.  SHAPE=VM.Standard.A1.Flex bash lethe.sh

  COMPARTMENT_ID       $OCI_TENANCY in Cloud Shell, else the tenancy from ~/.oci/config
  SHAPE                VM.Standard.E2.1.Micro (or VM.Standard.A1.Flex)
  A1_OCPUS             2      A1_MEMORY_GB  12   (Flex shapes only)
  UBUNTU_VERSION       24.04  UBUNTU_MINIMAL false
  TCP_PORTS            443    (22 is always open)
  UDP_PORTS            443
  SWAP_GB              2      (0 disables swap)
  SSH_KEY              ~/.ssh/oci_key (generated if missing)
  EXTRA_PUBKEY         your own SSH public key line, added to the server
  INSTANCE_NAME        ubuntu-free
  LAUNCH_RETRIES       30     RETRY_DELAY      60  (on "Out of host capacity")
  SSH_RETRIES          60     SSH_RETRY_DELAY  10
  OCI_CLI_PROFILE      profile in ~/.oci/config (default DEFAULT)

More: https://github.com/primevil/lethe
EOF
}

# ------------------------------ ENVIRONMENT --------------------------------
# macos, debian (also Ubuntu, Mint...), fedora, rhel (also Oracle Linux,
# Rocky, Alma, CentOS), arch or unknown. LETHE_UNAME / LETHE_OS_RELEASE are for tests.
detect_os() {
  local kernel="${LETHE_UNAME:-}" os_release="${LETHE_OS_RELEASE:-/etc/os-release}" id="" like=""
  [[ -n "$kernel" ]] || kernel=$(uname -s 2>/dev/null || echo unknown)
  if [[ "$kernel" == Darwin ]]; then echo macos; return; fi
  if [[ -r "$os_release" ]]; then
    # shellcheck disable=SC1090
    id=$(. "$os_release" && echo "${ID:-}")
    # shellcheck disable=SC1090
    like=$(. "$os_release" && echo "${ID_LIKE:-}")
  fi
  case "$id" in
    debian|ubuntu)                       echo debian; return ;;
    fedora)                              echo fedora; return ;;
    rhel|ol|centos|rocky|almalinux)      echo rhel;   return ;;
    arch|manjaro|endeavouros)            echo arch;   return ;;
  esac
  case " $like " in
    *" debian "*|*" ubuntu "*) echo debian ;;
    *" arch "*)                echo arch ;;
    *" rhel "*|*" centos "*)   echo rhel ;;
    *" fedora "*)              echo fedora ;;
    *)                         echo unknown ;;
  esac
}

# Commands that install the OCI CLI, jq and the OpenSSH client on an OS
install_commands() {
  case "$1" in
    macos)
      echo "brew install oci-cli jq" ;;
    debian)
      echo "sudo apt-get update"
      echo "sudo apt-get install -y jq openssh-client pipx"
      echo "pipx install oci-cli"
      echo "pipx ensurepath" ;;
    fedora)
      echo "sudo dnf install -y jq openssh-clients pipx"
      echo "pipx install oci-cli"
      echo "pipx ensurepath" ;;
    rhel)
      echo "sudo dnf install -y jq openssh-clients python3-pip"
      echo "python3 -m pip install --user oci-cli" ;;
    arch)
      echo "sudo pacman -S --needed --noconfirm jq openssh python-pipx"
      echo "pipx install oci-cli"
      echo "pipx ensurepath" ;;
    *)
      echo "# Install jq and the OpenSSH client with your package manager, then the OCI CLI:"
      echo "# https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm" ;;
  esac
}

# Exits with install instructions when a required command is missing
check_deps() {
  local missing=() cmd line
  for cmd in oci jq ssh ssh-keygen; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) && return 0
  {
    printf '\n\033[1;31mERROR:\033[0m Missing: %s\n' "${missing[*]}"
    if [[ " ${missing[*]} " == *" oci "* && -x "$HOME/.local/bin/oci" ]]; then
      printf '    oci is installed in ~/.local/bin, which is not in your PATH.\n'
      printf '    Run "pipx ensurepath" (or add ~/.local/bin to PATH) and open a new terminal.\n'
    fi
    printf '    Install with:\n\n'
    install_commands "$(detect_os)" | while IFS= read -r line; do printf '      %s\n' "$line"; done
    printf '\n    Then log in once with "oci setup bootstrap".\n'
    printf '    Or run lethe.sh in OCI Cloud Shell, where everything is preinstalled.\n'
  } >&2
  exit 1
}

# Tenancy OCID of $OCI_CLI_PROFILE (default DEFAULT) in the OCI CLI config;
# like the CLI, falls back to the DEFAULT section
config_tenancy() {
  local cfg="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}" profile="${OCI_CLI_PROFILE:-DEFAULT}" p t
  [[ -r "$cfg" ]] || return 0
  for p in "$profile" DEFAULT; do
    t=$(awk -v want="[$p]" '
          /^[[:space:]]*\[/ { s = $0; gsub(/[[:space:]]/, "", s); in_p = (s == want); next }
          in_p && /^[[:space:]]*tenancy[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }
        ' "$cfg")
    if [[ -n "$t" ]]; then echo "$t"; return 0; fi
  done
}

# The OCI CLI has neither a config file nor another auth method (Cloud Shell)
oci_unconfigured() {
  [[ -z "${OCI_CLI_AUTH:-}" && ! -f "${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}" ]]
}

# Exits with a hint when the OCI CLI cannot authenticate or see the compartment
check_auth() {
  local err
  if err=$(oci iam compartment get --compartment-id "$C" 2>&1 >/dev/null); then
    return 0
  fi
  printf '%s\n' "$err" >> "$LOGF"
  if oci_unconfigured; then
    die "The OCI CLI is not configured. Run \"oci setup bootstrap\" once (it opens the browser), then re-run lethe.sh."
  fi
  printf '%s\n' "$err" | tail -n 5 >&2
  die "The OCI CLI cannot access compartment $C (profile ${OCI_CLI_PROFILE:-DEFAULT}). Check ~/.oci/config or run \"oci setup bootstrap\" again."
}

# ------------------------------ VALIDATION ---------------------------------
is_uint() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }

# validate_ports NAME "443 8443"
validate_ports() {
  local name="$1" p
  for p in $2; do
    if ! is_uint "$p" || (( p < 1 || p > 65535 )); then
      die "$name: invalid port \"$p\" (expected numbers 1-65535 separated by spaces)."
    fi
  done
}

validate_settings() {
  local v
  [[ -n "$COMPARTMENT_ID" ]] \
    || die "Set COMPARTMENT_ID (it defaults to \$OCI_TENANCY in Cloud Shell and to the tenancy in ~/.oci/config elsewhere)."
  [[ "$INSTANCE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "INSTANCE_NAME may contain only letters, digits, '.', '_' and '-'."
  validate_ports TCP_PORTS "$TCP_PORTS"
  validate_ports UDP_PORTS "$UDP_PORTS"
  for v in SWAP_GB A1_OCPUS A1_MEMORY_GB LAUNCH_RETRIES RETRY_DELAY SSH_RETRIES SSH_RETRY_DELAY; do
    is_uint "${!v}" || die "$v must be a non-negative integer, got \"${!v}\"."
  done
  (( LAUNCH_RETRIES >= 1 )) || die "LAUNCH_RETRIES must be at least 1."
  (( SSH_RETRIES >= 1 ))    || die "SSH_RETRIES must be at least 1."
  if [[ "$SHAPE" == *Flex ]]; then
    (( A1_OCPUS >= 1 && A1_MEMORY_GB >= 1 )) || die "A1_OCPUS and A1_MEMORY_GB must be at least 1."
  fi
  [[ "$UBUNTU_MINIMAL" == true || "$UBUNTU_MINIMAL" == false ]] \
    || die "UBUNTU_MINIMAL must be \"true\" or \"false\", got \"$UBUNTU_MINIMAL\"."
  [[ "$UBUNTU_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] \
    || die "UBUNTU_VERSION must look like 24.04, got \"$UBUNTU_VERSION\"."
  if [[ -n "$EXTRA_PUBKEY" ]]; then
    [[ "$EXTRA_PUBKEY" != *$'\n'* \
       && "$EXTRA_PUBKEY" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] \
      || die "EXTRA_PUBKEY does not look like a single SSH public key line (\"ssh-ed25519 AAAA... comment\")."
  fi
}

# ------------------------------ BUILDERS -----------------------------------
# Security list ingress rules (JSON) for: ingress_rules "TCP_PORTS" "UDP_PORTS" VCN_CIDR
ingress_rules() {
  jq -n --arg tcp "$1" --arg udp "$2" --arg cidr "$3" '
    def ports(s): s | [splits("\\s+")] | map(select(length > 0) | tonumber) | unique;
    [ {source:"0.0.0.0/0", protocol:"6", tcpOptions:{destinationPortRange:{min:22, max:22}}},
      {source:"0.0.0.0/0", protocol:"1", icmpOptions:{type:3, code:4}},
      {source:$cidr,       protocol:"1", icmpOptions:{type:3}} ]
    + [ (ports($tcp) - [22])[] | {source:"0.0.0.0/0", protocol:"6",  tcpOptions:{destinationPortRange:{min:., max:.}}} ]
    + [  ports($udp)[]         | {source:"0.0.0.0/0", protocol:"17", udpOptions:{destinationPortRange:{min:., max:.}}} ]
  '
}

# Opens TCP/UDP ports in an iptables-persistent rules file and removes the
# OCI image's REJECT rule from the FORWARD chain. Runs on the server (it is
# copied into the cloud-init script), so it relies on GNU sed.
patch_iptables_rules() {
  local rules="$1" tcp="$2" udp="$3" p
  sed -i '/^-A FORWARD -j REJECT --reject-with icmp-host-prohibited/d' "$rules"
  for p in $tcp; do
    grep -q -- "-p tcp .*--dport $p -j ACCEPT" "$rules" || \
      sed -i "/^-A INPUT -j REJECT/i -A INPUT -p tcp -m state --state NEW -m tcp --dport $p -j ACCEPT" "$rules"
  done
  for p in $udp; do
    grep -q -- "-p udp .*--dport $p -j ACCEPT" "$rules" || \
      sed -i "/^-A INPUT -j REJECT/i -A INPUT -p udp -m udp --dport $p -j ACCEPT" "$rules"
  done
}

# Script run on the server at first boot (cloud-init)
render_user_data() {
  echo '#!/bin/bash'
  printf 'SWAP_GB=%q\nTCP_PORTS=%q\nUDP_PORTS=%q\n' "$SWAP_GB" "$TCP_PORTS" "$UDP_PORTS"
  declare -f patch_iptables_rules
  cat << 'BOOTSTRAP'
set -euxo pipefail
exec > /var/log/vpn-bootstrap.log 2>&1
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# 1. Swap: with 1 GB RAM, apt and Docker tend to crash without it
if [ "$SWAP_GB" -gt 0 ] && ! swapon --show | grep -q '^/swapfile'; then
  fallocate -l "${SWAP_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 2. Packages: SFTP is required by the Amnezia client to upload files
$APT update
$APT -y upgrade
$APT install -y openssh-sftp-server iptables-persistent docker.io curl netcat-openbsd
$APT install -y docker-buildx || true
usermod -aG docker ubuntu
systemctl enable docker

# 3. Firewall: OCI images block FORWARD and every port except 22
RULES=/etc/iptables/rules.v4
if [ -f "$RULES" ]; then
  patch_iptables_rules "$RULES" "$TCP_PORTS" "$UDP_PORTS"
  iptables-restore < "$RULES"
fi
# Docker recreates its own rules after iptables-restore
systemctl restart docker

echo "BOOTSTRAP OK"
BOOTSTRAP
}

# ------------------------------ OCI STEPS ----------------------------------
# First availability domain that offers $SHAPE (empty if none)
find_availability_domain() {
  local ad
  for ad in $(oci iam availability-domain list -c "$C" 2>>"$LOGF" | jq -r '.data[].name'); do
    if oci compute shape list -c "$C" --availability-domain "$ad" --all 2>>"$LOGF" \
         | jq -e --arg s "$SHAPE" '[.data[]? | select(.shape == $s)] | length > 0' >/dev/null; then
      echo "$ad"
      return 0
    fi
  done
}

# Runs "oci LAUNCH_ARGS..." and prints the new instance id. Retries while the
# error mentions capacity; any other error is fatal.
launch_with_retry() {
  local i out
  for ((i = 1; i <= LAUNCH_RETRIES; i++)); do
    if out=$(oci "$@" 2>"$WORKDIR/launch.err"); then
      jq -r '.data.id' <<< "$out"
      return 0
    fi
    cat "$WORKDIR/launch.err" >> "$LOGF"
    if grep -qi 'capacity' "$WORKDIR/launch.err"; then
      info "Out of capacity (attempt $i/$LAUNCH_RETRIES), retrying in ${RETRY_DELAY}s..." >&2
      sleep "$RETRY_DELAY"
    else
      cat "$WORKDIR/launch.err" >&2
      die "Failed to launch the instance."
    fi
  done
  die "Still out of capacity after $LAUNCH_RETRIES attempts. Try again later."
}

# ---------------------------------------------------------------------------
main() {
  set -euo pipefail
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "$WORKDIR"' EXIT
  trap 'printf "\n\033[1;31mSomething went wrong (line %s). Details: %s\033[0m\n" "$LINENO" "$LOGF" >&2' ERR
  : > "$LOGF"

  log "Checking environment"
  check_deps
  if [[ -z "$COMPARTMENT_ID" ]]; then
    oci_unconfigured \
      && die "The OCI CLI is not configured. Run \"oci setup bootstrap\" once (it opens the browser), then re-run lethe.sh."
    COMPARTMENT_ID=$(config_tenancy)
  fi
  validate_settings
  C="$COMPARTMENT_ID"
  check_auth
  info "Compartment: $C"
  info "Shape:       $SHAPE"
  info "Log:         $LOGF"

  # -------------------------------------------------------------------------
  log "Network: VCN"
  VCN_ID=$(oci network vcn list -c "$C" --display-name "$VCN_NAME" --all 2>>"$LOGF" | pick_available)
  if [[ -z "$VCN_ID" ]]; then
    VCN_ID=$(oci network vcn create -c "$C" --cidr-block "$VCN_CIDR" \
              --display-name "$VCN_NAME" --dns-label freevcn \
              --wait-for-state AVAILABLE 2>>"$LOGF" | jq -r '.data.id')
    info "Created $VCN_NAME"
  else
    info "Reusing existing $VCN_NAME"
  fi

  log "Network: internet gateway"
  IGW_ID=$(oci network internet-gateway list -c "$C" --vcn-id "$VCN_ID" --all 2>>"$LOGF" | pick_available)
  if [[ -z "$IGW_ID" ]]; then
    IGW_ID=$(oci network internet-gateway create -c "$C" --vcn-id "$VCN_ID" --is-enabled true \
              --display-name "$IGW_NAME" --wait-for-state AVAILABLE 2>>"$LOGF" | jq -r '.data.id')
    info "Created $IGW_NAME"
  else
    info "Reusing existing internet gateway"
  fi

  log "Network: default route to the internet"
  RT_ID=$(oci network vcn get --vcn-id "$VCN_ID" 2>>"$LOGF" | jq -r '.data."default-route-table-id"')
  oci network route-table update --rt-id "$RT_ID" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW_ID\"}]" \
    >/dev/null 2>>"$LOGF"
  info "0.0.0.0/0 -> internet gateway"

  log "Network: public subnet"
  SUBNET_ID=$(oci network subnet list -c "$C" --vcn-id "$VCN_ID" --display-name "$SUBNET_NAME" --all 2>>"$LOGF" | pick_available)
  if [[ -z "$SUBNET_ID" ]]; then
    SUBNET_ID=$(oci network subnet create -c "$C" --vcn-id "$VCN_ID" --cidr-block "$SUBNET_CIDR" \
                 --display-name "$SUBNET_NAME" --dns-label pub --route-table-id "$RT_ID" \
                 --wait-for-state AVAILABLE 2>>"$LOGF" | jq -r '.data.id')
    info "Created $SUBNET_NAME"
  else
    info "Reusing existing $SUBNET_NAME"
  fi

  log "Network: port rules (security list)"
  SL_ID=$(oci network subnet get --subnet-id "$SUBNET_ID" 2>>"$LOGF" | jq -r '.data."security-list-ids"[0]')
  ingress_rules "$TCP_PORTS" "$UDP_PORTS" "$VCN_CIDR" > "$WORKDIR/ingress.json"
  oci network security-list update --security-list-id "$SL_ID" \
    --ingress-security-rules "file://$WORKDIR/ingress.json" --force >/dev/null 2>>"$LOGF"
  info "TCP: 22 $TCP_PORTS"
  info "UDP: $UDP_PORTS"

  # -------------------------------------------------------------------------
  log "Checking whether instance \"$INSTANCE_NAME\" already exists"
  EXISTING=$(oci compute instance list -c "$C" --display-name "$INSTANCE_NAME" --all 2>>"$LOGF" | pick_live_instance)
  if [[ -n "$EXISTING" ]]; then
    IP=$(oci compute instance list-vnics --instance-id "$EXISTING" 2>>"$LOGF" | jq -r '.data[0]."public-ip" // "none"')
    info "Instance already exists (IP: $IP). Only the network and ports were updated."
    info "To rebuild it from scratch, terminate it first:"
    info "  oci compute instance terminate --instance-id $EXISTING --force --wait-for-state TERMINATED"
    exit 0
  fi
  info "Not found, creating a new one"

  # -------------------------------------------------------------------------
  log "Looking for an availability domain that offers $SHAPE"
  AD=$(find_availability_domain)
  [[ -n "$AD" ]] || die "Shape $SHAPE is not offered in any availability domain of this region."
  info "$AD"

  # -------------------------------------------------------------------------
  log "Selecting the Ubuntu image"
  if [[ "$UBUNTU_MINIMAL" == "true" ]]; then OS_VER="$UBUNTU_VERSION Minimal"; else OS_VER="$UBUNTU_VERSION"; fi
  IMAGES=$(oci compute image list -c "$C" --shape "$SHAPE" --operating-system "Canonical Ubuntu" \
            --operating-system-version "$OS_VER" --sort-by TIMECREATED --sort-order DESC --all 2>>"$LOGF" || true)
  IMG_ID=$(jq -r '[.data[]?] | .[0].id // empty' <<< "$IMAGES")
  IMG_NAME=$(jq -r '[.data[]?] | .[0]."display-name" // empty' <<< "$IMAGES")
  if [[ -z "$IMG_ID" ]]; then
    AVAIL=$(oci compute image list -c "$C" --shape "$SHAPE" --operating-system "Canonical Ubuntu" --all 2>>"$LOGF" \
            | jq -r '[.data[]?."operating-system-version"] | unique | join(", ")')
    die "No Ubuntu \"$OS_VER\" image for $SHAPE. Available versions: $AVAIL"
  fi
  info "$IMG_NAME"

  # -------------------------------------------------------------------------
  log "SSH keys"
  if [[ ! -f "$SSH_KEY" ]]; then
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -q
    info "Generated $SSH_KEY"
  else
    info "Using $SSH_KEY"
  fi
  cp "$SSH_KEY.pub" "$WORKDIR/authorized_keys"
  if [[ -n "$EXTRA_PUBKEY" ]]; then
    echo "$EXTRA_PUBKEY" >> "$WORKDIR/authorized_keys"
    info "Added your extra public key"
  fi

  render_user_data > "$WORKDIR/user-data.sh"

  # -------------------------------------------------------------------------
  log "Launching instance \"$INSTANCE_NAME\""
  LAUNCH_ARGS=(compute instance launch -c "$C" --availability-domain "$AD"
    --shape "$SHAPE" --image-id "$IMG_ID" --subnet-id "$SUBNET_ID"
    --assign-public-ip true --display-name "$INSTANCE_NAME"
    --ssh-authorized-keys-file "$WORKDIR/authorized_keys"
    --user-data-file "$WORKDIR/user-data.sh"
    --wait-for-state RUNNING)
  if [[ "$SHAPE" == *Flex ]]; then
    LAUNCH_ARGS+=(--shape-config "{\"ocpus\":$A1_OCPUS,\"memoryInGBs\":$A1_MEMORY_GB}")
  fi
  INST_ID=$(launch_with_retry "${LAUNCH_ARGS[@]}")

  IP=$(oci compute instance list-vnics --instance-id "$INST_ID" 2>>"$LOGF" | jq -r '.data[0]."public-ip"')
  info "Instance is running, public IP: $IP"

  # -------------------------------------------------------------------------
  log "Waiting for SSH"
  ssh-keygen -R "$IP" >/dev/null 2>&1 || true
  SSH_OPTS=(-n -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5
            -o BatchMode=yes -o ServerAliveInterval=30)
  SSH_UP=0
  for ((i = 1; i <= SSH_RETRIES; i++)); do
    if ssh "${SSH_OPTS[@]}" "ubuntu@$IP" true 2>/dev/null; then SSH_UP=1; break; fi
    sleep "$SSH_RETRY_DELAY"
  done
  [[ "$SSH_UP" == 1 ]] || die "SSH not responding. Check the instance in the OCI console."
  info "SSH is up"

  log "Waiting for server setup (swap, packages, firewall). On a micro VM this takes 5-15 min."
  if ssh "${SSH_OPTS[@]}" "ubuntu@$IP" \
       'sudo cloud-init status --wait >/dev/null 2>&1; sudo tail -n 1 /var/log/vpn-bootstrap.log' \
       | grep -q 'BOOTSTRAP OK'; then
    BOOT_OK=1
  else
    BOOT_OK=0
  fi

  # -------------------------------------------------------------------------
  log "Done"
  if [[ "$BOOT_OK" == 1 ]]; then
    info "Server configured successfully."
  else
    info "WARNING: server setup may have failed. Check the log on the server:"
    info "  ssh -i $SSH_KEY ubuntu@$IP 'sudo tail -50 /var/log/vpn-bootstrap.log'"
  fi
  cat << EOF

    Public IP:     $IP
    SSH login:     ssh -i $SSH_KEY ubuntu@$IP
    Open ports:    TCP 22 $TCP_PORTS | UDP $UDP_PORTS

    In the Amnezia client, add a server:
      - address:   $IP
      - user:      ubuntu
      - key:       SSH private key (e.g. $SSH_KEY or your own)
    Then install the Xray protocol on port 443.

    Check, with the VPN connected (should print ip=$IP):
      curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep ip=
EOF
}

# Tests source this file with LETHE_LIB_ONLY=1 to get the functions only
if [[ "${LETHE_LIB_ONLY:-}" != 1 ]]; then
  main "$@"
fi
