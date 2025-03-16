#!/bin/bash

## SSH Oneliner
#  curl -fsSL https://raw.githubusercontent.com/GaryPuckett/Hypercuube_Scripts/main/Rocky/Cockpit_Podman.sh -k | sudo bash

## ERROR Handling Func
error_handler() {
  echo "An error occurred on line $1: $2"
  read -rp "Do you want to continue? (y/n): " CHOICE < /dev/tty
  if [[ "$CHOICE" != "y" ]]; then
    echo "Exiting script."
    exit 1
  fi
}
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR


# Check if running as root; if not, re‑exec with sudo
if [[ $EUID -ne 0 ]]; then
  echo "Not running as root; re‑executing with sudo..."
  exec sudo bash "$0" "$@"
fi


# Get the main network interface IP
SERVER_IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')
SERVER_IPV6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{print $7; exit}')


## 0. Introductory Output
echo "Cockpit Rocky-Linux Podman Setup Script v1.19"
echo "IPv4 address: $SERVER_IP"
echo "IPv6 address: $SERVER_IPV6"
echo "Hostname: $(hostname)"

read -rp "Change Hostname? (leave blank to keep): " NEW_HOSTNAME < /dev/tty
if [[ -n "$NEW_HOSTNAME" ]]; then
  hostnamectl set-hostname "$NEW_HOSTNAME"
  echo "127.0.0.1 $NEW_HOSTNAME" >> /etc/hosts
  echo "Hostname updated to: $(hostname)"
fi

## 0.5 Rocky ajust current mirrorlist to official source for OSPP compatibility
echo "Adjusting repository files for strong certificate keys..."
for repo in /etc/yum.repos.d/*.repo; do
  if grep -q "mirrors.rockylinux.org" "$repo"; then
    echo "Modifying $repo"
    # Comment out mirrorlist lines
    sed -i 's|^mirrorlist=.*|#&|' "$repo"
    # Uncomment or add baseurl lines that point to the official download site.
    # For example, for BaseOS, AppStream, and Extras:
    if grep -q "^#baseurl=" "$repo"; then
      sed -i 's|^#baseurl=|baseurl=|g' "$repo"
    else
      # If there is no baseurl, insert one based on the repo id.
      # (This example assumes the repo id is in the filename.)
      case "$repo" in
        *BaseOS*.repo)
          echo "baseurl=https://dl.rockylinux.org/$contentdir/$releasever/BaseOS/$basearch/os/" >> "$repo"
          ;;
        *AppStream*.repo)
          echo "baseurl=https://dl.rockylinux.org/$contentdir/$releasever/AppStream/$basearch/os/" >> "$repo"
          ;;
        *Extras*.repo)
          echo "baseurl=https://dl.rockylinux.org/$contentdir/$releasever/Extras/$basearch/os/" >> "$repo"
          ;;
      esac
    fi
  fi
done



## 1. Upgrade to 'Protected Profile' and Clear Firewall Rules
echo "Updating package index and upgrading packages..."
dnf update -y
dnf upgrade -y

# Ensure known SCAP file exists.
if [ -f /usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml ]; then
    SCAP_FILE="/usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml"
else
    echo "Error: No valid SCAP content file found. Please install the scap-security-guide package."
    exit 1
fi

# Ensure the scap-security-guide package is installed.
if ! rpm -q scap-security-guide &>/dev/null; then
    echo "scap-security-guide package is missing. Installing..."
    dnf install -y scap-security-guide || { echo "Installation failed. Exiting."; exit 1; }
fi

echo "Using SCAP file: $SCAP_FILE"

# Install OpenSCAP and the SCAP Security Guide
echo "Installing OpenSCAP and SCAP Security Guide..."
dnf install -y openscap-scanner scap-security-guide

# Apply the 'OSPP' security profile
echo "Applying the 'protected' security profile..."
oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_ospp --remediate $SCAP_FILE

# Clear existing iptables rules
echo "Clearing the iptables 4 & 6..."
iptables -F
ip6tables -F

## 2. Set up Firewall Rules (IPv4 & IPv6)
echo "Setting up IPv4 firewall rules..."
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 9090 -j ACCEPT
iptables -P INPUT DROP

echo "Setting up IPv6 firewall rules..."
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -p udp --dport 53 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 53 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 9090 -j ACCEPT
ip6tables -P INPUT DROP


## 3. Install Fail2ban
dnf install -y epel-release
dnf install -y fail2ban

# Backup original jail configuration if it exists
[ -f /etc/fail2ban/jail.conf ] && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.conf.bak

# Create local jail configuration for SSH and Cockpit
tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
# Use systemd backend to read journal logs (available in Fail2ban 0.11+)
backend = systemd

[sshd]
enabled = true

[cockpit]
enabled = true
# Cockpit listens on port 9090 by default.
port    = 9090
# Use a custom filter named 'cockpit' (see below).
filter  = cockpit
# If cockpit logs to a file instead of journal, specify its path here.
# For example: logpath = /var/log/cockpit/cockpit.log
EOF

# Create a basic filter for cockpit.
# This example filter is very basic and may need adjustments to match your cockpit log messages.
tee /etc/fail2ban/filter.d/cockpit.conf > /dev/null <<'EOF'
[Definition]
# Adjust the failregex below to match authentication failures or suspicious messages in cockpit logs.
failregex = ^.*(Authentication failure|Failed login).* from <HOST>.*$
ignoreregex =
EOF

# Enable and start the Fail2ban service
systemctl enable --now fail2ban

echo "Fail2ban has been installed and configured to protect SSH and Cockpit."

## 4. Install and Configure Bind (DNS)
echo "Installing Bind and utilities..."
dnf install -y bind bind-utils

echo "Setting up BIND configuration for $(hostname)..."
mkdir -p /etc/named.conf.d
cat > /etc/named.conf.d/zone.conf <<EOF
zone "$(hostname)" {
    type master;
    file "/etc/named/db.$(hostname)";
};
EOF

echo "Creating zone file for $(hostname)..."
cat > /etc/named/db.$(hostname) <<EOF
\$TTL 86400
@    IN  SOA  ns1.$(hostname). admin.$(hostname). (
          $(date +%Y%m%d)01  ; Serial
          3600        ; Refresh
          1800        ; Retry
          604800      ; Expire
          86400       ; Minimum TTL
)
@    IN  NS   ns1.$(hostname).
@    IN  NS   ns2.$(hostname).
EOF

if [ -n "$SERVER_IP" ]; then
  echo "ns1    IN  A    $SERVER_IP" >> /etc/named/db.$(hostname)
fi
if [ -n "$SERVER_IPV6" ]; then
  echo "ns1    IN  AAAA $SERVER_IPV6" >> /etc/named/db.$(hostname)
fi

if [ -n "$SERVER_IP" ]; then
  echo "ns2    IN  A    $SERVER_IP" >> /etc/named/db.$(hostname)
fi
if [ -n "$SERVER_IPV6" ]; then
  echo "ns2    IN  AAAA $SERVER_IPV6" >> /etc/named/db.$(hostname)
fi

if [ -n "$SERVER_IP" ]; then
  echo "@    IN  A    $SERVER_IP" >> /etc/named/db.$(hostname)
fi
if [ -n "$SERVER_IPV6" ]; then
  echo "@    IN  AAAA $SERVER_IPV6" >> /etc/named/db.$(hostname)
fi

echo "Restarting Bind..."
systemctl restart named
systemctl enable named


## 5. Make irqbalance & rescue work
# Create the drop-in directory for irqbalance service overrides
mkdir -p /etc/systemd/system/irqbalance.service.d
# Write the override configuration to disable private user namespaces
tee /etc/systemd/system/irqbalance.service.d/override.conf > /dev/null <<'EOF'
[Service]
PrivateUsers=no
EOF

# Create the override directory if it doesn't exist
mkdir -p /etc/systemd/system/rescue.target.d

# Create an override file that clears the AllowIsolate setting
tee /etc/systemd/system/rescue.target.d/override.conf > /dev/null <<'EOF'
[Unit]
AllowIsolate=
EOF

# Reload systemd to pick up the changes
systemctl daemon-reload
# Restart irqbalance for the changes to take effect
systemctl restart irqbalance
systemctl restart rescue

echo "Override applied: PrivateUsers has been set to no for irqbalance."



echo "Performing system cleanup..."
dnf update -y
dnf autoremove -y
dnf clean all

## LAST Enable Cockpit
systemctl enable --now cockpit.socket

## Display
echo "-------------------------------------------------"
echo ""
echo "Installation complete!"
echo "Hostname: $(hostname)"
echo "Cockpit is available at: https://$SERVER_IP:9090"
echo "Set DNS glue records to: $SERVER_IP and $SERVER_IPV6"
