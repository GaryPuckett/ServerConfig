#!/bin/bash
set -e

## SSH Oneliner
#  curl -fsSL https://raw.githubusercontent.com/GaryPuckett/Hypercuube_Scripts/main/Webmin_Docker.sh | sudo bash

# Get the main network interface IP
SERVER_IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')
SERVER_IPV6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{print $7; exit}')
DOMAIN="hypercuube.net"

## 0. Set hostname before continuing
echo "Setting hostname to hypercuube.net..."
sudo hostnamectl set-hostname $DOMAIN
echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts

# Verify the change
echo "Hostname is now: $(hostname)"

## 1. Install Docker and Docker Compose
echo "Updating package index..."
sudo apt-get update

echo "Installing prerequisites for Docker..."
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release

echo "Adding Docker's official GPG key..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "Setting up the Docker stable repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Updating package index with Docker repo..."
sudo apt-get update

echo "Installing Docker Engine, CLI, containerd, and Docker Compose plugin..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Add current user to docker group to run docker without sudo.
echo "Adding current user ($USER) to docker group..."
sudo usermod -aG docker $USER

## 2. Install Webmin
echo "Downloading Webmin repository setup script..."
curl -o webmin-setup-repos.sh https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repos.sh

echo "Running Webmin repository setup script..."
sudo sh webmin-setup-repos.sh -f

echo "Updating package index..."
sudo apt-get update

echo "Installing Webmin..."
sudo apt-get install -y webmin --install-recommends

## 3. Install Docker Webmin Module
echo "Installing the Docker Webmin module..."
wget -O docker.wbm.gz https://github.com/dave-lang/webmin-docker/releases/latest/download/docker.wbm.gz
gunzip docker.wbm.gz
sudo /usr/share/webmin/install-module.pl docker.wbm

## 4. Install and Configure Bind9
# Install BIND9 if not installed
echo "Installing BIND9..."
sudo apt update && sudo apt install -y bind9 bind9-utils bind9-dnsutils

# Configure the DNS Zone
echo "Setting up BIND zone for $DOMAIN..."
sudo bash -c "cat > /etc/bind/named.conf.local" <<EOF
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
};
EOF

echo "Creating zone file for $DOMAIN..."
# Create the zone file with both A and AAAA records.
sudo bash -c "cat > /etc/bind/db.$DOMAIN" <<EOF
\$TTL 86400
@    IN  SOA  ns1.$DOMAIN. ns2.$DOMAIN. (
          $(date +%Y%m%d)01  ; Serial
          3600        ; Refresh
          1800        ; Retry
          604800      ; Expire
          86400       ; Minimum TTL
)
     IN  NS   ns.$DOMAIN.

; IPv4 address record
@    IN  A    $SERVER_IP

; IPv6 address record
@    IN  AAAA $SERVER_IPV6

; www subdomain records
www  IN  A    $SERVER_IP
www  IN  AAAA $SERVER_IPV6
EOF

# Restart BIND to apply changes
echo "Restarting BIND9..."
sudo systemctl restart bind9

# Enable BIND to start on boot
sudo systemctl enable bind9

## 5. Update & Restart Webmin to apply changes
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y
sudo apt autoclean -y
sudo systemctl restart webmin

## Fin

echo "Installation complete!"
echo "-------------------------------------------------"
echo "Hostname is: $(hostname)"
echo "Webmin is available at: https://$SERVER_IP:10000"
echo "You may need to log out and log back in for group changes to take effect."
