#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: lucasfell
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://ghostfol.io/ | Github: https://github.com/ghostfolio/ghostfolio

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential wget sudo libvips-dev \
  ca-certificates 

$STD sudo apt-get install golang git gcc nodejs ffmpeg -y
#NODE_VERSION="24" setup_nodejs

msg_ok "Installed Dependencies"

fetch_and_deploy_gh_release "stash" "stashapp/stash" "tarball" "latest" "/opt/stashapp"

msg_info "Setup Stashapp"
cd /opt/stashapp
$STD npm ci
$STD npm run build:production
msg_ok "Built Stashapp"

msg_info "Setting up Environment"
cat <<EOF >/opt/stashapp/.env
DATABASE_URL=postgresql://stash:stash@192.168.71.15:5432/stashbox?connect_timeout=300&sslmode=prefer
NODE_ENV=production
PORT=3333
HOST=0.0.0.0
TZ=Etc/UTC
EOF

msg_ok "Set up Environment"

msg_info "Running Database Migrations"
cd /opt/stashapp
$STD npx prisma migrate deploy
$STD npx prisma db seed
msg_ok "Database Migrations Complete"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/stashapp.service
[Unit]
Description=Stashapp

[Service]
Type=simple
User=root
WorkingDirectory=/opt/stashapp/dist/apps/api
Environment=NODE_ENV=production
EnvironmentFile=/opt/stashapp/.env
ExecStart=/usr/bin/node main.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now stashapp
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
