#!/bin/bash
set -euxo pipefail

# --- Install Docker + Compose plugin from Docker's official apt repo ---
apt-get update -y
apt-get install -y ca-certificates curl gnupg git

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

usermod -aG docker ubuntu
newgrp docker
# --- Clone the repo (the repo root IS the app dir) ---
sudo -u ubuntu git clone ${repo_url} /home/ubuntu/skillpulse

# --- Build the .env file for compose ---
sudo -u ubuntu cp /home/ubuntu/skillpulse/.env.example /home/ubuntu/skillpulse/.env
echo "DOCKERHUB_USERNAME=${dockerhub_username}" | sudo -u ubuntu tee -a /home/ubuntu/skillpulse/.env

# Compose will pull the backend image from Docker Hub on first `up` (after CI runs once).
