#!/bin/bash
# Run as root on a new Ubuntu server.
# Connect with: ssh -A root@<newserver>  (agent forwarding required for auto-signing)
set -euo pipefail

TOM="nick@tom"
NAME=$(hostname -s)
NAME_LOWER=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
NAME_UPPER=$(echo "$NAME" | tr '[:lower:]' '[:upper:]')
NAME_TITLE=$(echo "$NAME_LOWER" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
IP=$(hostname -I | awk '{print $1}')

TOM_USER_CA_PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINC9Khi3GLlzHOFlzZVLE1xJXhEN5qPCW3gCSAdHVm7g Tom User CA"
TOM_HOST_CA_PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMBobXiJCfE3mb3niwj4ynngKK2NSUuTeEhW+Q8UWq7F Tom Host CA"

echo "=== SSH CA Onboarding: $NAME ($IP) ==="
echo ""
echo "Default host cert principals (all case variants):"
echo "  $NAME_LOWER  $NAME_UPPER  $NAME_TITLE"
echo "  $NAME_LOWER.lan  $NAME_UPPER.lan  $NAME_TITLE.lan"
echo ""
read -rp "Additional names to include in cert (space-separated, blank to skip): " EXTRA_NAMES
DEFAULT_PRINCIPALS="$NAME_LOWER,$NAME_UPPER,$NAME_TITLE,$NAME_LOWER.lan,$NAME_UPPER.lan,$NAME_TITLE.lan"
if [ -n "$EXTRA_NAMES" ]; then
  EXTRA_PRINCIPALS=$(echo "$EXTRA_NAMES" | tr ' ' ',')
  ALL_HOST_PRINCIPALS="$DEFAULT_PRINCIPALS,$EXTRA_PRINCIPALS"
else
  ALL_HOST_PRINCIPALS="$DEFAULT_PRINCIPALS"
fi
echo ""

# --- 1. Trust Tom-signed user certs for incoming connections ---
echo "[1/6] Configuring TrustedUserCAKeys..."
echo "$TOM_USER_CA_PUB" > /etc/ssh/tom_user_ca.pub
chmod 644 /etc/ssh/tom_user_ca.pub
grep -q TrustedUserCAKeys /etc/ssh/sshd_config \
  || echo 'TrustedUserCAKeys /etc/ssh/tom_user_ca.pub' >> /etc/ssh/sshd_config

# --- 2. Trust Tom's host CA for outgoing SSH ---
echo "[2/6] Trusting Tom host CA in /etc/ssh/ssh_known_hosts..."
if ! grep -q "$TOM_HOST_CA_PUB" /etc/ssh/ssh_known_hosts 2>/dev/null; then
  echo "@cert-authority * $TOM_HOST_CA_PUB" >> /etc/ssh/ssh_known_hosts
fi

# --- 3. Generate root user key (ed25519) if missing ---
echo "[3/6] Checking root user key..."
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [ ! -f /root/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
  echo "      Generated new ed25519 key."
else
  echo "      Key already exists."
fi

# --- 4 & 5. Sign keys via Tom and install certs ---
# Open one multiplexed connection to Tom — single password prompt for everything
CTRL="/tmp/tom_ctl_${NAME}"
SSHOPTS="-o ControlPath=$CTRL -o ControlMaster=no -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
cleanup_ctrl() { ssh -O exit -o ControlPath="$CTRL" "$TOM" 2>/dev/null || true; }
trap cleanup_ctrl EXIT

echo "[4/6] Connecting to Tom (enter password/passphrase once)..."
ssh -fNM -o ControlPath="$CTRL" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$TOM"

echo "  Copying keys to Tom..."
scp $SSHOPTS /etc/ssh/ssh_host_ed25519_key.pub /root/.ssh/id_ed25519.pub "$TOM:/tmp/"

echo "[5/6] Signing on Tom (you will be prompted for each CA passphrase)..."
ssh -t $SSHOPTS "$TOM" "
  ssh-keygen -s ~/.ssh/ca/tom_host_ca -I '${NAME}' -h \
    -n '${ALL_HOST_PRINCIPALS}' -V +52w /tmp/ssh_host_ed25519_key.pub && \
  ssh-keygen -s ~/.ssh/ca/tom_user_ca -I '${NAME}' -n nick,root \
    -V +52w /tmp/id_ed25519.pub
"

echo "  Retrieving signed certs..."
scp $SSHOPTS "$TOM:/tmp/ssh_host_ed25519_key-cert.pub" /etc/ssh/ssh_host_ed25519_key-cert.pub
scp $SSHOPTS "$TOM:/tmp/id_ed25519-cert.pub"           /root/.ssh/id_ed25519-cert.pub
ssh $SSHOPTS "$TOM" "rm -f /tmp/ssh_host_ed25519_key.pub /tmp/ssh_host_ed25519_key-cert.pub /tmp/id_ed25519.pub /tmp/id_ed25519-cert.pub"

chmod 644 /etc/ssh/ssh_host_ed25519_key-cert.pub
chmod 600 /root/.ssh/id_ed25519-cert.pub

grep -q HostCertificate /etc/ssh/sshd_config \
  || echo 'HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub' >> /etc/ssh/sshd_config

# --- 6. Restart sshd ---
echo "[6/6] Restarting sshd..."
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

echo ""
echo "=== Done! $NAME is fully onboarded. ==="
echo ""
echo "Verify from another machine:"
echo "  ssh root@$IP 'echo ok'"
echo ""
echo "Optional - disable password auth (do this only after verifying cert login works):"
echo "  grep -q 'PasswordAuthentication no' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config && systemctl restart ssh"
