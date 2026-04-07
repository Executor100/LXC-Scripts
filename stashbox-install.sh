#!/usr/bin/env bash
set -e

# ===== CONFIG DEFAULT (EDITABLE INTERACTIVO) =====
APP="stash-box"
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

HOSTNAME="stashbox"
DISK="8G"
RAM="2048"
CORES="2"
TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"

echo "🚀 Creando LXC $CTID..."

pct create $CTID $TEMPLATE \
  -hostname $HOSTNAME \
  -cores $CORES \
  -memory $RAM \
  -rootfs local-lvm:$DISK \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -unprivileged 1

pct start $CTID
sleep 5

echo "📦 Instalando dependencias..."

pct exec $CTID -- bash -c "
apt update && apt upgrade -y
apt install -y git build-essential libvips-dev wget
"

echo "⬇️ Instalando Go..."

pct exec $CTID -- bash -c "
wget -q https://go.dev/dl/go1.22.5.linux-amd64.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz
echo 'export PATH=\$PATH:/usr/local/go/bin' >> /root/.bashrc
"

echo "📥 Instalando Stash-Box..."

pct exec $CTID -- bash -c "
export PATH=\$PATH:/usr/local/go/bin
git clone https://github.com/stashapp/stash-box.git /opt/stash-box
cd /opt/stash-box
make build
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
