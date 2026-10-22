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
set -euo pipefail

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
# ---------------------------------------------------------------------------

LOGF="${LOGF:-$HOME/lethe.log}"
WORKDIR="$(mktemp -d)"
: > "$LOGF"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'printf "\n\033[1;31mSomething went wrong (line %s). Details: %s\033[0m\n" "$LINENO" "$LOGF" >&2' ERR

# First AVAILABLE object from a "list" response
pick_available() { jq -r '[.data[]? | select(."lifecycle-state"=="AVAILABLE")] | .[0].id // empty'; }

# ---------------------------------------------------------------------------
log "Checking environment"
command -v oci >/dev/null || die "OCI CLI not found. Run this script in OCI Cloud Shell."
command -v jq  >/dev/null || die "jq not found."
[[ -n "$COMPARTMENT_ID" ]] || die "Set COMPARTMENT_ID (in Cloud Shell it defaults to \$OCI_TENANCY)."
C="$COMPARTMENT_ID"
info "Compartment: $C"
info "Shape:       $SHAPE"
info "Log:         $LOGF"

# ---------------------------------------------------------------------------
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
jq -n --arg tcp "$TCP_PORTS" --arg udp "$UDP_PORTS" --arg cidr "$VCN_CIDR" '
  def ports(s): s | split(" ") | map(select(length > 0) | tonumber) | unique;
  [ {source:"0.0.0.0/0", protocol:"6", tcpOptions:{destinationPortRange:{min:22, max:22}}},
    {source:"0.0.0.0/0", protocol:"1", icmpOptions:{type:3, code:4}},
    {source:$cidr,       protocol:"1", icmpOptions:{type:3}} ]
  + [ (ports($tcp) - [22])[] | {source:"0.0.0.0/0", protocol:"6",  tcpOptions:{destinationPortRange:{min:., max:.}}} ]
  + [  ports($udp)[]         | {source:"0.0.0.0/0", protocol:"17", udpOptions:{destinationPortRange:{min:., max:.}}} ]
' > "$WORKDIR/ingress.json"
oci network security-list update --security-list-id "$SL_ID" \
  --ingress-security-rules "file://$WORKDIR/ingress.json" --force >/dev/null 2>>"$LOGF"
info "TCP: 22 $TCP_PORTS"
info "UDP: $UDP_PORTS"

# ---------------------------------------------------------------------------
log "Checking whether instance \"$INSTANCE_NAME\" already exists"
EXISTING=$(oci compute instance list -c "$C" --display-name "$INSTANCE_NAME" --all 2>>"$LOGF" \
  | jq -r '[.data[]? | select(."lifecycle-state" as $s
              | ["PROVISIONING","STARTING","RUNNING","STOPPING","STOPPED"] | index($s))]
           | .[0].id // empty')
if [[ -n "$EXISTING" ]]; then
  IP=$(oci compute instance list-vnics --instance-id "$EXISTING" 2>>"$LOGF" | jq -r '.data[0]."public-ip" // "none"')
  info "Instance already exists (IP: $IP). Only the network and ports were updated."
  info "To rebuild it from scratch, terminate it first:"
  info "  oci compute instance terminate --instance-id $EXISTING --force --wait-for-state TERMINATED"
  exit 0
fi
info "Not found, creating a new one"

# ---------------------------------------------------------------------------
log "Looking for an availability domain that offers $SHAPE"
AD=""
for ad in $(oci iam availability-domain list -c "$C" 2>>"$LOGF" | jq -r '.data[].name'); do
  if oci compute shape list -c "$C" --availability-domain "$ad" --all 2>>"$LOGF" \
       | jq -e --arg s "$SHAPE" '[.data[]? | select(.shape == $s)] | length > 0' >/dev/null; then
    AD="$ad"; break
  fi
done
[[ -n "$AD" ]] || die "Shape $SHAPE is not offered in any availability domain of this region."
info "$AD"

# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Script run on the server at first boot (cloud-init)
{
  echo '#!/bin/bash'
  echo "SWAP_GB=\"$SWAP_GB\""
  echo "TCP_PORTS=\"$TCP_PORTS\""
  echo "UDP_PORTS=\"$UDP_PORTS\""
  cat << 'BOOTSTRAP'
set -euxo pipefail
exec > /var/log/vpn-bootstrap.log 2>&1
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# 1. Swap: with 1 GB RAM, apt and Docker tend to crash without it
if ! swapon --show | grep -q '^/swapfile'; then
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
  sed -i '/^-A FORWARD -j REJECT --reject-with icmp-host-prohibited/d' "$RULES"
  for p in $TCP_PORTS; do
    grep -q -- "-p tcp .*--dport $p -j ACCEPT" "$RULES" || \
      sed -i "/^-A INPUT -j REJECT/i -A INPUT -p tcp -m state --state NEW -m tcp --dport $p -j ACCEPT" "$RULES"
  done
  for p in $UDP_PORTS; do
    grep -q -- "-p udp .*--dport $p -j ACCEPT" "$RULES" || \
      sed -i "/^-A INPUT -j REJECT/i -A INPUT -p udp -m udp --dport $p -j ACCEPT" "$RULES"
  done
  iptables-restore < "$RULES"
fi
# Docker recreates its own rules after iptables-restore
systemctl restart docker

echo "BOOTSTRAP OK"
BOOTSTRAP
} > "$WORKDIR/user-data.sh"

# ---------------------------------------------------------------------------
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

INST_ID=""
for ((i = 1; i <= LAUNCH_RETRIES; i++)); do
  if OUT=$(oci "${LAUNCH_ARGS[@]}" 2>"$WORKDIR/launch.err"); then
    INST_ID=$(jq -r '.data.id' <<< "$OUT")
    break
  fi
  cat "$WORKDIR/launch.err" >> "$LOGF"
  if grep -qi 'capacity' "$WORKDIR/launch.err"; then
    info "Out of capacity (attempt $i/$LAUNCH_RETRIES), retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
  else
    cat "$WORKDIR/launch.err" >&2
    die "Failed to launch the instance."
  fi
done
[[ -n "$INST_ID" ]] || die "Still out of capacity after $LAUNCH_RETRIES attempts. Try again later."

IP=$(oci compute instance list-vnics --instance-id "$INST_ID" 2>>"$LOGF" | jq -r '.data[0]."public-ip"')
info "Instance is running, public IP: $IP"

# ---------------------------------------------------------------------------
log "Waiting for SSH"
ssh-keygen -R "$IP" >/dev/null 2>&1 || true
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5
          -o BatchMode=yes -o ServerAliveInterval=30)
SSH_UP=0
for ((i = 1; i <= 60; i++)); do
  if ssh "${SSH_OPTS[@]}" "ubuntu@$IP" true 2>/dev/null; then SSH_UP=1; break; fi
  sleep 10
done
[[ "$SSH_UP" == 1 ]] || die "SSH not responding after 10 minutes. Check the instance in the OCI console."
info "SSH is up"

log "Waiting for server setup (swap, packages, firewall). On a micro VM this takes 5-15 min."
if ssh "${SSH_OPTS[@]}" "ubuntu@$IP" \
     'sudo cloud-init status --wait >/dev/null 2>&1; sudo tail -n 1 /var/log/vpn-bootstrap.log' \
     | grep -q 'BOOTSTRAP OK'; then
  BOOT_OK=1
else
  BOOT_OK=0
fi

# ---------------------------------------------------------------------------
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
EOF
