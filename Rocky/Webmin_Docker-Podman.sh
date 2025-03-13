#!/bin/bash

## SSH Oneliner
#  curl -fsSL https://raw.githubusercontent.com/GaryPuckett/Hypercuube_Scripts/main/Rocky/Webmin_Docker-Podman.sh -k | sudo bash

#  This script is meant to be ran on a fresh ubuntu installation to install:
#  Docker + Compose,         | -Enables Namespace Mapping
#  Webmin + Docker Module,   |
#  Fail2Ban + PAM,           | -Configures Webmin Auth - Configures SSH & Webmin Jails
#  Bind9                     | 
#  
#  This script sets up a docker ubuntu server with webmin to interface with it.
#  Script reduces attack surface to PAM Authentication and
#
#  NOTE: Will reset iptables and ip6tables & Allow SSH, DNS, & Webmin through IPv4&6
#

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
echo "Ubuntu Webmin Docker v1.14"
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



## 2. Install Docker-Podman
echo "Installing Docker-Podman..."
dnf install -y podman-docker



## 3. Set up Firewall Rules (IPv4 & IPv6)
echo "Setting up IPv4 firewall rules..."
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 10000 -j ACCEPT
iptables -P INPUT DROP

echo "Setting up IPv6 firewall rules..."
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -p udp --dport 53 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 53 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 10000 -j ACCEPT
ip6tables -P INPUT DROP



## 4. Install Webmin
echo "Adding Webmin Repository..."
curl -k -o jcameron-key.asc https://download.webmin.com/jcameron-key.asc
rpm --import jcameron-key.asc

cat > /etc/yum.repos.d/webmin.repo <<'EOF'
[Webmin]
name=Webmin Distribution Neutral
baseurl=https://download.webmin.com/download/yum
enabled=1
gpgcheck=1
gpgkey=https://download.webmin.com/jcameron-key.asc
sslverify=1
EOF


dnf clean all
dnf update -y

echo "Downloading Webmin repository setup script..."
curl -k -o webmin-setup-repos.sh https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repos.sh

echo "Running Webmin repository setup script..."
sh webmin-setup-repos.sh

echo "Updating package index for Webmin..."
dnf update -y

echo "Installing Webmin..."
dnf install webmin



## 5. Install Docker Webmin Module
echo "Installing the Docker Webmin module..."
wget -k -O docker.wbm.gz https://github.com/dave-lang/webmin-docker/releases/latest/download/docker.wbm.gz
gunzip -f docker.wbm.gz
/usr/share/webmin/install-module.pl docker.wbm



## 6. Install Fail2Ban and PAM Authentication
echo "Enabling EPEL repository for extra packages..."
dnf install -y epel-release

echo "Installing Fail2Ban and google-authenticator-libpam..."
dnf install -y fail2ban google-authenticator-libpam

echo "Configuring Webmin to use PAM authentication..."
sed -i 's/^passwd_mode=.*/passwd_mode=2/' /etc/webmin/miniserv.conf
sed -i 's/^pam=.*$/pam=1/' /etc/webmin/miniserv.conf

echo "Restarting Webmin service..."
systemctl restart webmin

echo "Creating basic fail2ban configuration..."
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
maxretry = 3
findtime = 15m
bantime = 20m

[webmin-auth]
enabled = true
journalmatch = _SYSTEMD_UNIT=webmin.service
EOF

echo "Restarting and enabling Fail2Ban..."
systemctl restart fail2ban
systemctl enable fail2ban



## 7. Install and Configure Bind (DNS)
echo "Installing Bind and utilities..."
dnf install -y bind bind-utils

echo "Setting up BIND configuration for $(hostname)..."
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



## 8. Install Zip and System Cleanup
echo "Installing zip..."
dnf install -y zip

echo "Performing system cleanup..."
dnf update -y
dnf autoremove -y
dnf clean all
systemctl restart webmin
/usr/share/webmin/reload



## Finishing Up
echo "-------------------------------------------------"
echp ""
echo "Installation complete!"
echo "Hostname: $(hostname)"
echo "Webmin is available at: https://$SERVER_IP:10000"
echo "Set DNS glue records to: $SERVER_IP and $SERVER_IPV6"
