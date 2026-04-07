#!/usr/bin/env bash
set -e

clear
echo "🚀 Instalando StashBox en un contenedor LXC de Proxmox..."

# ===== CONFIG DEFAULT (EDITABLE INTERACTIVO) =====
APP="stash-box"
# Obtener siguiente CTID automáticamente
CTID=$(pvesh get /cluster/nextid)

read -p "IP PostgreSQL: " DB_HOST
read -p "Puerto PostgreSQL [5432]: " DB_PORT
DB_PORT=${DB_PORT:-5432}

read -p "Nombre DB [stashbox]: " DB_NAME
DB_NAME=${DB_NAME:-stashbox}

read -p "Usuario DB [stash]: " DB_USER
DB_USER=${DB_USER:-stash}

read -s -p "Password DB: " DB_PASS
echo ""

# Detectar almacenamiento LVM-thin automáticamente
STORAGE=$(pvesm status | awk '/lvmthin/ {print $1; exit}')

if [ -z "$STORAGE" ]; then
  echo "❌ No se encontró almacenamiento LVM-thin (local-lvm)"
  exit 1
fi

echo "📦 Usando storage: $STORAGE"
echo "🆔 CTID asignado: $CTID"

# Actualizar templates
echo "🔄 Actualizando templates..."
pveam update

# Descargar template Debian 12 si no existe
TEMPLATE=$(pveam available | awk '/debian-12/ {print $2; exit}')
if ! pveam list local | grep -q "$TEMPLATE"; then
  echo "⬇️ Descargando template $TEMPLATE..."
  pveam download local $TEMPLATE
else
  echo "✅ Template ya existe"
fi

HOSTNAME="stashbox"
DISK="8G"
RAM="2048"
CORES="2"
#TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"

echo "🚀 Creando LXC $CTID..."
# Crear contenedor
echo "📦 Creando contenedor..."
pct create $CTID local:vztmpl/$TEMPLATE \
  --hostname stashbox \
  --rootfs ${STORAGE}:8 \
  --memory 1024 \
  --cores 2 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 1 \
  --features nesting=1

echo "▶️ Iniciando contenedor..."
pct start $CTID
sleep 5

echo "📦 Instalando dependencias..."

echo "⚙️ Instalando dependencias dentro del CT..."
pct exec $CTID -- bash -c "
apt update && apt upgrade -y
apt install -y curl build-essential git &&
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - &&
apt install -y nodejs
apt install -y git build-essential libvips-dev wget
"

pct exec $CTID -- bash -c "
apt update && apt install sudo -y
"
# Instalar pnpm
echo "⚙️ Instalando pnpm..."
pct exec $CTID -- bash -c "
npm install -g pnpm --force
export PATH=\$PATH:/usr/local/bin
pnpm -v
"

echo "⬇️ Instalando Go..."

pct exec $CTID -- bash -c "
wget -q https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz
echo 'export PATH=\$PATH:/usr/local/go/bin' >> /root/.bashrc
echo 'export PATH=\$PATH:/usr/local/bin'
"

echo "📥 Instalando Stash-Box..."

echo "Clonando Stash-Box..."
pct exec $CTID -- bash -c "
export PATH=\$PATH:/usr/local/go/bin
git clone https://github.com/stashapp/stash-box.git /opt/stash-box
"
echo "Instalando dependencias Stash-Box..."
pct exec $CTID -- bash -c "
cd /opt/stash-box
cd frontend
pnpm install
cd ..
go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest
export PATH=$PATH:$(go env GOPATH)/bin
"

echo "Generando Stash-Box..."
pct exec $CTID -- bash -c "
cd /opt/stash-box
export NODE_OPTIONS="--max-old-space-size=4096"
make generate
make ui build
"

echo "⚙️ Configurando..."

pct exec $CTID -- bash -c "
mkdir -p /etc/stash-box

cat <<EOF > /etc/stash-box/config.yml
database:
  connectionString: postgres://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME?sslmode=disable

host: 0.0.0.0
port: 9998
EOF
"

echo "🔧 Creando servicio..."

pct exec $CTID -- bash -c "
cat <<EOF > /etc/systemd/system/stash-box.service
[Unit]
Description=Stash-Box
After=network.target

[Service]
ExecStart=/opt/stash-box/stash-box --config /etc/stash-box/config.yml
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable stash-box
systemctl start stash-box
"

IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

echo ""
echo "✅ Listo!"
echo "🌐 http://$IP:9998"
