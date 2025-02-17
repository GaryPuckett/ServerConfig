#!/bin/bash
set -e

## SSH Oneliner
#  curl -fsSL https://raw.githubusercontent.com/GaryPuckett/Hypercuube_Scripts/main/Webmin_Docker.sh | sudo bash

## 0. Set hostname before continuing
echo "Setting hostname to hypercuube.net..."
sudo hostnamectl set-hostname hypercuube.net

# Update /etc/hosts
echo "127.0.0.1 hypercuube.net" | sudo tee -a /etc/hosts

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

# Restart Webmin to apply changes
sudo systemctl restart webmin

## Fin
# Get the main network interface IP
SERVER_IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')

echo "Installation complete!"
echo "-------------------------------------------------"
echo "Hostname is: $(hostname)"
echo "Webmin is available at: https://$SERVER_IP:10000"
echo "You may need to log out and log back in for group changes to take effect."
