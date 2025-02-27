#!/bin/bash

## SSH Oneliner
#  curl -fsSL https://raw.githubusercontent.com/GaryPuckett/Hypercuube_Scripts/main/Webmin_Docker.sh | sudo bash

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

# Get the main network interface IP
SERVER_IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')
SERVER_IPV6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{print $7; exit}')

## 0. Captive Portion
echo "Webmin Docker v1.19"
echo "IPv4 address: $SERVER_IP"
echo "IPv6 address: $SERVER_IPV6"
echo "Hostname: $(hostname)"

read -rp "Change Hostname? (leave blank to keep): " NEW_HOSTNAME < /dev/tty
if [[ -n "$NEW_HOSTNAME" ]]; then
  sudo hostnamectl set-hostname "$NEW_HOSTNAME"
  echo "127.0.0.1 $NEW_HOSTNAME" | sudo tee -a /etc/hosts
  echo "Hostname updated to: $(hostname)"
fi

## 1. Install Docker and Docker Compose
echo "Updating package index..."
sudo apt-get update
sudo apt-get -y upgrade

# Clear Firewall rules
sudo iptables -F
sudo ip6tables -F

echo "Installing prerequisites for Docker..."
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release

echo "Adding Docker's official GPG key..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "Setting up the Docker stable repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Updating package index with Docker repo..."
sudo apt-get -y update

echo "Installing Docker Engine, CLI, containerd, and Docker Compose plugin..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

USERNAME="dockerusr"
GROUPNAME="dockergrp"

# Create or overwrite the daemon.json with userns-remap setting
sudo cat > "$DAEMON_CONFIG" <<EOF
{
  "userns-remap": "default"
}
EOF
echo "User Namespace Remapping enabled."

# Restrict Docker Socket Access
echo "Restricting Docker Socket Access..."
sudo chown root:docker /var/run/docker.sock
sudo chmod 660 /var/run/docker.sock
echo "Docker Socket permissions set to 660."

# Restart Docker Service to Apply Changes
echo "Restarting Docker Service..."
systemctl restart docker
echo "Docker Service restarted."

## 2. Install Webmin
echo "Downloading Webmin repository setup script..."
curl -o webmin-setup-repos.sh https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repos.sh

echo "Running Webmin repository setup script..."
sudo sh webmin-setup-repos.sh -f

echo "Updating package index..."
sudo apt-get -y update

echo "Installing Webmin..."
sudo apt-get install -y webmin --install-recommends

## 3. Install Docker Webmin Module
echo "Installing the Docker Webmin module..."
wget -O docker.wbm.gz https://github.com/dave-lang/webmin-docker/releases/latest/download/docker.wbm.gz
gunzip -f docker.wbm.gz
sudo /usr/share/webmin/install-module.pl docker.wbm

## 4. Install Fail2Ban & PAM
echo "Installing fail2ban & PAM..."
sudo apt-get -y update
sudo apt-get install -y libpam-google-authenticator fail2ban

# Enable PAM authentication in Webmin
echo "Configuring Webmin to use PAM authentication..."
sudo sed -i 's/^passwd_mode=.*/passwd_mode=2/' /etc/webmin/miniserv.conf
sudo sed -i 's/^pam=.*$/pam=1/' /etc/webmin/miniserv.conf

echo "Restarting Webmin..."
sudo systemctl restart webmin

# Config jails for SSH and Webmin-auth
echo "Creating a basic fail2ban configuration..."
sudo bash -c "cat > /etc/fail2ban/jail.local" <<EOF
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
sudo systemctl restart fail2ban
sudo systemctl enable fail2ban
echo "Fail2Ban & PAM setup complete!"

## 5. Install and Configure Bind9
# Install BIND9 if not installed
echo "Installing BIND9..."
sudo apt update && sudo apt install -y bind9 bind9-utils bind9-dnsutils

# Configure the DNS Zone
echo "Setting up BIND zone for $(hostname)..."
sudo bash -c "cat > /etc/bind/named.conf.local" <<EOF
zone "$(hostname)" {
    type master;
    file "/etc/bind/db.$(hostname)";
};
EOF

echo "Creating zone file for $(hostname)..."
# Create the zone file
sudo bash -c "cat > /etc/bind/db.$(hostname)" <<EOF
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

# NS1 Records
if [ -n "$SERVER_IP" ]; then
  echo "Adding A record for ns1.$SERVER_IP..."
  sudo bash -c "echo 'ns1    IN  A    $SERVER_IP' >> /etc/bind/db.$(hostname)"
fi
if [ -n "$SERVER_IPV6" ]; then
  echo "Adding AAAA record for ns1.$SERVER_IPV6..."
  sudo bash -c "echo 'ns1    IN  AAAA $SERVER_IPV6' >> /etc/bind/db.$(hostname)"
fi

# NS2 Records
if [ -n "$SERVER_IP" ]; then
  echo "Adding A record for ns2.$SERVER_IP..."
  sudo bash -c "echo 'ns2    IN  A    $SERVER_IP' >> /etc/bind/db.$(hostname)"
fi
if [ -n "$SERVER_IPV6" ]; then
  echo "Adding AAAA record for ns2.$SERVER_IPV6..."
  sudo bash -c "echo 'ns2    IN  AAAA $SERVER_IPV6' >> /etc/bind/db.$(hostname)"
fi

# TLD Records
if [ -n "$SERVER_IP" ]; then
  echo "Adding A record for $SERVER_IP..."
  sudo bash -c "echo '@    IN  A    $SERVER_IP' >> /etc/bind/db.$(hostname)"
fi
if [ -n "$SERVER_IPV6" ]; then
  echo "Adding AAAA record for $SERVER_IPV6..."
  sudo bash -c "echo '@    IN  AAAA $SERVER_IPV6' >> /etc/bind/db.$(hostname)"
fi

# WWW Records
#if [ -n "$SERVER_IP" ]; then
#  sudo bash -c "echo 'www  IN  A    $SERVER_IP' >> /etc/bind/db.$(hostname)"
#fi
#if [ -n "$SERVER_IPV6" ]; then
#  sudo bash -c "echo 'www  IN  AAAA $SERVER_IPV6' >> /etc/bind/db.$(hostname)"
#fi

## 5. Add Firewall Rules
# IPv4
echo "Setting up IPv4 firewall"
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A INPUT -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 53 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 10000 -j ACCEPT
sudo iptables -P INPUT DROP
# IPv6
echo "Setting up IPv6 firewall"
sudo ip6tables -A INPUT -i lo -j ACCEPT
sudo ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo ip6tables -A INPUT -p udp --dport 53 -j ACCEPT
sudo ip6tables -A INPUT -p tcp --dport 53 -j ACCEPT
sudo ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
sudo ip6tables -A INPUT -p tcp --dport 10000 -j ACCEPT
sudo ip6tables -P INPUT DROP

# Restart BIND to apply changes
echo "Restarting BIND9..."
sudo systemctl restart named
sudo systemctl enable named

## 5. Install Perl WebminAPI
#wget https://www.webmin.com/Webmin-API-1.0.tar.gz
#tar xvzf Webmin-API-1.0.tar.gz
#cd Webmin-API-1.0
#perl Makefile.PL
#sudo apt install make
#sudo make install
#cd ..
#rm -rf Webmin-API-1.0.tar.gz Webmin-API-1.0

## 6. Update & Restart Webmin to apply changes
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y
sudo apt autoclean -y
sudo systemctl restart webmin
sudo /etc/webmin/reload

## Fin
echo "-------------------------------------------------"
echo "Installation complete!"
echo "Hostname is: $(hostname)"
echo "Webmin is available at: https://$SERVER_IP:10000"
echo "Set GLUE records to: $SERVER_IP and $SERVER_IPV6"
