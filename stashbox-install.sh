#!/usr/bin/env bash

set -euo pipefail

# ===== COLORES =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ===== LOG =====
LOGFILE="stashbox-install.log"
exec > >(tee -i $LOGFILE)
exec 2>&1

clear

echo -e "${GREEN}"
echo "╔══════════════════════════════════════╗"
echo "║     🚀 Stash-Box LXC Installer      ║"
echo "║        Proxmox Helper Style         ║"
echo "╚══════════════════════════════════════╝"
echo -e "${NC}"

# ===== FLAGS =====
AUTO=false

if [[ "${1:-}" == "--auto" ]]; then
  AUTO=true
fi

# ===== INPUT =====
if [ "$AUTO" = false ]; then
  read -p "IP PostgreSQL: " DB_HOST
  read -p "Puerto [5432]: " DB_PORT
  DB_PORT=${DB_PORT:-5432}

  read -p "DB Name [stashbox]: " DB_NAME
  DB_NAME=${DB_NAME:-stashbox}

  read -p "Usuario [stash]: " DB_USER
  DB_USER=${DB_USER:-stash}

  read -s -p "Password: " DB_PASS
  echo ""
else
  DB_HOST="192.168.71.15"
  DB_PORT="5432"
  DB_NAME="stashbox"
  DB_USER="stash"
  DB_PASS="stash"
fi

# ===== VALIDACIONES =====
echo -e "${YELLOW}🔎 Validando entorno...${NC}"

command -v pct >/dev/null || { echo -e "${RED}❌ pct no encontrado${NC}"; exit 1; }
command -v pvesh >/dev/null || { echo -e "${RED}❌ pvesh no encontrado${NC}"; exit 1; }

# ===== STORAGE =====
STORAGE=$(pvesm status | awk '/lvmthin/ {print $1; exit}')
if [ -z "$STORAGE" ]; then
  echo -e "${RED}❌ No LVM-thin detectado${NC}"
  exit 1
fi

CTID=$(pvesh get /cluster/nextid)

echo -e "${GREEN}✔ Storage: $STORAGE${NC}"
echo -e "${GREEN}✔ CTID: $CTID${NC}"

# ===== TEMPLATE =====
echo -e "${YELLOW}📦 Preparando template...${NC}"

if ! pveam update; then
  echo -e "${YELLOW}⚠️ Warning: fallo en salida de pveam, continuando...${NC}"
fi

#TEMPLATE=$(pveam available | awk '/debian-12/ {print $2; exit}')
TEMPLATE=$(pveam available 2>/dev/null | grep debian-12 | head -n1 | awk '{print $2}')

if ! pveam list local | grep -q "$TEMPLATE"; then
  pveam download local $TEMPLATE
fi

# ===== CREAR CT =====
echo -e "${YELLOW}🚀 Creando contenedor...${NC}"

pct create $CTID local:vztmpl/$TEMPLATE \
  --hostname stashbox \
  --rootfs ${STORAGE}:8 \
  --memory 2048 \
  --cores 2 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 \
  --features nesting=1

pct start $CTID

echo -e "${YELLOW}⏳ Esperando red...${NC}"
sleep 5

# ===== INSTALL CORE =====
echo -e "${YELLOW}⚙️ Instalando dependencias...${NC}"

pct exec $CTID -- bash -c "
set -e

apt update && apt upgrade -y
apt install -y curl git build-essential wget sudo libvips-dev ca-certificates

# Node LTS
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - &&
apt install -y nodejs

# pnpm
npm install -g pnpm
ln -sf \$(which pnpm) /usr/local/bin/pnpm

# Go
cd /tmp
wget -q https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz
ln -sf /usr/local/go/bin/go /usr/local/bin/go
echo 'export PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' > /etc/profile.d/go.sh
chmod +x /etc/profile.d/go.sh

# Verificación
go version
node -v
pnpm -v
"

# ===== CLONAR =====
echo -e "${YELLOW}📥 Instalando Stash-Box...${NC}"

pct exec $CTID -- bash -c "
set -e
git clone https://github.com/stashapp/stash-box.git /opt/stash-box
"

# ===== BUILD =====
echo -e "${YELLOW}🔨 Build...${NC}"

pct exec $CTID -- bash -c "
set -e
export PATH=/usr/local/go/bin:\$PATH
cd /opt/stash-box/frontend
pnpm install

cd /opt/stash-box
go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest
ln -sf /root/go/bin/sqlc /usr/local/bin/sqlc
sqlc version

export NODE_OPTIONS='--max-old-space-size=4096'

make generate
make ui build
"

# ===== CONFIG =====
echo -e "${YELLOW}⚙️ Configurando...${NC}"

pct exec $CTID -- bash -c "cat > /etc/stash-box.yml <<EOF
database:
  connectionString: postgres://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME?sslmode=disable
host: 0.0.0.0
port: 9998
EOF"

# ===== SERVICE =====
echo -e "${YELLOW}🔧 Creando servicio...${NC}"

pct exec $CTID -- bash -c "
cat > /etc/systemd/system/stash-box.service <<EOF
[Unit]
Description=Stash-Box
After=network.target

[Service]
ExecStart=/opt/stash-box/stash-box --config /etc/stash-box.yml
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable stash-box
systemctl start stash-box
"

# ===== RESULT =====
IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}✅ Instalación completa${NC}"
echo -e "${GREEN}🌐 http://$IP:9998${NC}"
echo -e "${YELLOW}📄 Log: $LOGFILE${NC}"
