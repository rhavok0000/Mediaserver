#!/bin/bash
# ==============================================================
# Jellyfin Media Server - Post-Install Script
# Se ejecuta automáticamente después de instalar Debian
# ==============================================================
set -euo pipefail

# Asegurar que /usr/local/bin esté en el PATH (necesario en entorno in-target)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG="/var/log/jellyfin-setup.log"
exec > >(tee -a "$LOG") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n${GREEN}==> $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }

# ==============================================================
# 1. Repositorios con non-free y firmware
# ==============================================================
step "[1/10] Configurando repositorios..."

cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOF

apt-get update -qq

# ==============================================================
# 2. Firmware WiFi (cubre los chips más comunes del mercado)
# ==============================================================
step "[2/10] Instalando drivers WiFi..."

apt-get install -y --no-install-recommends \
    firmware-linux \
    firmware-linux-nonfree \
    firmware-iwlwifi \
    firmware-realtek \
    firmware-atheros \
    firmware-brcm80211 \
    firmware-ralink \
    firmware-mediatek \
    firmware-misc-nonfree \
    wireless-tools \
    wpasupplicant \
    network-manager \
    rfkill \
    fuse3

# Actualizar initramfs para que el kernel cargue el firmware al arrancar
update-initramfs -u -k all

# ==============================================================
# 3. Instalar Jellyfin
# ==============================================================
step "[3/10] Instalando Jellyfin..."

curl -fsSL https://repo.jellyfin.org/install-jellyfin.sh | bash

# ==============================================================
# 4. Estructura de carpetas de medios
# ==============================================================
step "[4/10] Creando carpetas de medios..."

mkdir -p /media/peliculas
mkdir -p /media/musica
mkdir -p /media/fotos
mkdir -p /media/series
mkdir -p /media/nube          # Punto de montaje para la nube

# Permisos: usuario mediaserver y jellyfin pueden acceder
chown -R mediaserver:mediaserver /media
chmod -R 775 /media

# Añadir jellyfin al grupo del usuario y a video/render (aceleración hardware)
usermod -aG mediaserver jellyfin 2>/dev/null || true
usermod -aG video       jellyfin 2>/dev/null || true
usermod -aG render      jellyfin 2>/dev/null || true

# ==============================================================
# 5. Filebrowser - subir archivos desde el celular fácilmente
# ==============================================================
step "[5/10] Instalando Filebrowser (subida desde celular)..."

# Descargar e instalar el binario oficial
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

# Crear directorio de configuración
mkdir -p /etc/filebrowser

# Base de datos con config inicial
filebrowser config init --database /etc/filebrowser/filebrowser.db
filebrowser config set \
    --database /etc/filebrowser/filebrowser.db \
    --address 0.0.0.0 \
    --port 8080 \
    --root /media \
    --log /var/log/filebrowser.log

# Usuario admin por defecto (misma clave que el sistema)
filebrowser users add admin jellyfin123 \
    --database /etc/filebrowser/filebrowser.db \
    --perm.admin

# Servicio systemd para Filebrowser
cat > /etc/systemd/system/filebrowser.service <<'EOF'
[Unit]
Description=Filebrowser - Gestor de archivos web
After=network.target

[Service]
User=mediaserver
Group=mediaserver
ExecStart=/usr/local/bin/filebrowser \
    --database /etc/filebrowser/filebrowser.db
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Dar acceso de escritura al usuario mediaserver sobre la DB
chown -R mediaserver:mediaserver /etc/filebrowser

# ==============================================================
# 6. Rclone - montar Box.net como disco local (/media/nube)
# ==============================================================
step "[6/10] Instalando Rclone (Box.net como disco local)..."

curl -fsSL https://rclone.org/install.sh | bash

# Crear carpeta de configuración de rclone
mkdir -p /home/mediaserver/.config/rclone
chown -R mediaserver:mediaserver /home/mediaserver/.config

# Servicio systemd - monta Box.net en /media/nube al arrancar
# (se activa automáticamente tras correr: configurar-nube)
cat > /etc/systemd/system/rclone-nube.service <<'EOF'
[Unit]
Description=Rclone - Box.net montado en /media/nube
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=mediaserver
Group=mediaserver
ExecStart=/usr/bin/rclone mount nube: /media/nube \
    --config /home/mediaserver/.config/rclone/rclone.conf \
    --vfs-cache-mode full \
    --vfs-cache-max-size 2G \
    --vfs-read-chunk-size 32M \
    --dir-cache-time 72h \
    --allow-other \
    --buffer-size 256M \
    --log-level INFO \
    --log-file /var/log/rclone-nube.log
ExecStop=/bin/fusermount -u /media/nube
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Script de configuración guiada para Box.net
# Usa OAuth2: rclone abre un enlace → el usuario inicia sesión en Box
# La contraseña NUNCA se almacena en ningún archivo
cat > /usr/local/bin/configurar-nube <<'SCRIPT'
#!/bin/bash
set -euo pipefail

RCLONE_CONF="/home/mediaserver/.config/rclone/rclone.conf"

echo ""
echo "======================================================"
echo "  CONECTAR BOX.NET AL SERVIDOR"
echo "======================================================"
echo ""
echo "  Este proceso vincula tu cuenta de Box.net usando"
echo "  OAuth2. Tu contraseña NUNCA se guarda en el servidor."
echo ""
echo "  Necesitarás acceso a un navegador web (celular o PC)"
echo "  para autorizar el acceso cuando se te pida."
echo ""

# Crear configuración de Box en rclone de forma no interactiva
# excepto por el paso OAuth que requiere el navegador
sudo -u mediaserver rclone config create nube box \
    --config "$RCLONE_CONF" \
    --non-interactive 2>/dev/null || true

# Si el remote no quedó configurado con token, hacer auth manual
if ! sudo -u mediaserver rclone lsd nube: --config "$RCLONE_CONF" &>/dev/null 2>&1; then
    echo "  Se necesita autorizar el acceso a Box.net."
    echo ""
    echo "  Pasos:"
    echo "  1. Rclone mostrará un enlace a continuación"
    echo "  2. Ábrelo en el navegador de tu celular o PC"
    echo "  3. Inicia sesión en box.net con tu cuenta"
    echo "  4. Haz clic en 'Grant access to Box'"
    echo "  5. Vuelve aquí — la conexión se completará sola"
    echo ""
    read -rp "  Presiona Enter cuando estés listo..." _

    # Autorización OAuth interactiva
    sudo -u mediaserver rclone config reconnect nube: \
        --config "$RCLONE_CONF"
fi

echo ""
echo "  Verificando conexión con Box.net..."
if sudo -u mediaserver rclone lsd nube: --config "$RCLONE_CONF" 2>/dev/null; then
    echo ""
    echo "  Conexión exitosa!"
    echo ""

    # Crear carpetas en Box si no existen
    for folder in peliculas series musica fotos; do
        sudo -u mediaserver rclone mkdir "nube:/${folder}" \
            --config "$RCLONE_CONF" 2>/dev/null || true
    done

    echo "  Activando montaje automático al arrancar..."
    systemctl enable rclone-nube
    systemctl start  rclone-nube

    echo ""
    echo "  Box.net montado en: /media/nube"
    echo "  Jellyfin y Filebrowser ya pueden usarlo."
    echo ""
    echo "  Carpetas creadas en tu Box:"
    echo "    nube:/peliculas    nube:/series"
    echo "    nube:/musica       nube:/fotos"
else
    echo ""
    echo "  No se pudo conectar. Vuelve a intentarlo:"
    echo "  sudo configurar-nube"
fi
SCRIPT

chmod +x /usr/local/bin/configurar-nube

# Habilitar user_allow_other en fuse para que jellyfin vea el montaje
if ! grep -q "user_allow_other" /etc/fuse.conf; then
    echo "user_allow_other" >> /etc/fuse.conf
fi

# ==============================================================
# 7. Firewall
# ==============================================================
step "[7/10] Configurando firewall (UFW)..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 8096/tcp  comment 'Jellyfin HTTP'
ufw allow 8920/tcp  comment 'Jellyfin HTTPS'
ufw allow 8080/tcp  comment 'Filebrowser (subir desde celular)'
ufw allow 1900/udp  comment 'DLNA/SSDP discovery'
ufw allow 7359/udp  comment 'Jellyfin auto-discovery'
ufw allow 41641/udp comment 'Tailscale (acceso remoto)'
ufw --force enable

# ==============================================================
# 8. Tailscale - acceso remoto seguro desde cualquier lugar
# ==============================================================
step "[8/10] Instalando Tailscale (acceso remoto)..."

# Instalar Tailscale (VPN basada en WireGuard, gratis hasta 100 dispositivos)
curl -fsSL https://tailscale.com/install.sh | sh

# Habilitar el servicio al arranque (la autenticación se hace manualmente)
systemctl enable tailscaled

# Script de activación del acceso remoto (se corre una sola vez)
cat > /usr/local/bin/conectar-remoto <<'SCRIPT'
#!/bin/bash
echo ""
echo "======================================================"
echo "  ACTIVAR ACCESO REMOTO CON TAILSCALE"
echo "======================================================"
echo ""
echo "  PASO 1: Instala Tailscale en tu celular o PC:"
echo "    Android/iOS : busca 'Tailscale' en la tienda de apps"
echo "    Windows/Mac : https://tailscale.com/download"
echo ""
echo "  PASO 2: Crea una cuenta gratis en https://tailscale.com"
echo "          (puedes usar Google o Microsoft)"
echo ""
echo "  PASO 3: El servidor te mostrará un enlace."
echo "          Ábrelo en el navegador e inicia sesión"
echo "          con la misma cuenta de Tailscale."
echo ""
read -rp "  Presiona Enter para conectar el servidor..." _

# Conectar a Tailscale (abre URL de autenticación)
tailscale up

# Mostrar IP asignada por Tailscale
TS_IP=$(tailscale ip -4 2>/dev/null || echo "pendiente")

echo ""
echo "======================================================"
echo "  SERVIDOR CONECTADO!"
echo "======================================================"
echo ""
echo "  IP Tailscale del servidor: ${TS_IP}"
echo ""
echo "  Desde CUALQUIER lugar con Tailscale instalado:"
echo "    Jellyfin:     http://${TS_IP}:8096"
echo "    Filebrowser:  http://${TS_IP}:8080"
echo ""
echo "  Para ver tu IP Tailscale en el futuro:"
echo "    tailscale ip"
echo "======================================================"
SCRIPT

chmod +x /usr/local/bin/conectar-remoto

# Permitir que Tailscale acceda a la interfaz de red
if [ -f /etc/ufw/before.rules ]; then
    ufw allow in on tailscale0 2>/dev/null || true
fi

# ==============================================================
# 9. Habilitar servicios al arranque
# ==============================================================
step "[9/10] Habilitando servicios..."

systemctl daemon-reload
systemctl enable jellyfin
systemctl enable filebrowser
systemctl enable avahi-daemon
systemctl enable NetworkManager
systemctl enable tailscaled
systemctl enable ssh
# rclone-nube se activa manualmente con: configurar-nube

# ==============================================================
# 10. Mensaje final
# ==============================================================
step "[10/10] Instalación completada"

IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "IP-DEL-SERVIDOR")

echo ""
echo "======================================================"
echo "   JELLYFIN MEDIA SERVER - LISTO"
echo "======================================================"
echo ""
echo "  RED LOCAL:"
echo "    Jellyfin:     http://${IP}:8096"
echo "    Filebrowser:  http://${IP}:8080"
echo "    Usuario: admin  |  Contraseña: jellyfin123"
echo ""
echo "  ACCESO REMOTO (desde cualquier lugar):"
echo "    sudo conectar-remoto   ← ejecutar una sola vez"
echo "    Luego usa la IP de Tailscale en lugar de ${IP}"
echo ""
echo "  NUBE (Box.net como disco local):"
echo "    sudo configurar-nube   ← ejecutar una sola vez"
echo ""
echo "  CARPETAS DE MEDIOS:"
echo "    /media/peliculas  /media/series"
echo "    /media/musica     /media/fotos"
echo "    /media/nube  ← Box.net (tras configurar)"
echo ""
echo "  TELEVISORES:"
echo "    Samsung TV  →  busca 'Jellyfin' en la App Store"
echo "    LG webOS    →  busca 'Jellyfin' en LG Content Store"
echo "    DLNA        →  detectado automáticamente en la red"
echo ""
echo "  WiFi: Intel · Realtek · Atheros · Broadcom · Ralink · MediaTek"
echo ""
echo "  Usuario del sistema : mediaserver"
echo "  Contraseña          : jellyfin123  ← ¡CAMBIALA!"
echo "======================================================"
