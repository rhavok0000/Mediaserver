#!/bin/bash
# ==============================================================
# JELLYFIN MEDIA SERVER - Script de Instalación
# Compatible con Debian 12 (Bookworm) y Debian 13 (Trixie)
# Ejecutar vía SSH: sudo bash setup.sh
# ==============================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

# ─────────────────────────────────────────────────────────────
# Colores y helpers
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()  { echo -e "\n${GREEN}${BOLD}==> $*${NC}"; }
info()  { echo -e "${CYAN}    $*${NC}"; }
warn()  { echo -e "${YELLOW}[!] $*${NC}"; }
error() { echo -e "${RED}[ERROR] $*${NC}"; exit 1; }
ok()    { echo -e "${GREEN}    ✓ $*${NC}"; }

TOTAL_STEPS=10

# Detectar versión de Debian automáticamente
CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" || echo "")
if [[ -z "$CODENAME" ]]; then
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "bookworm")
fi
# trixie/sid usan "trixie" para security
if [[ "$CODENAME" == "sid" || "$CODENAME" == "unstable" ]]; then
    CODENAME="trixie"
fi

header() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         JELLYFIN MEDIA SERVER - Instalación              ║"
    echo "║         Debian ${CODENAME} · Servidor de Medios              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ─────────────────────────────────────────────────────────────
# Verificaciones previas
# ─────────────────────────────────────────────────────────────
header

if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse como root: sudo bash setup.sh"
fi

LOG="/var/log/jellyfin-setup.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

echo ""
info "Sistema detectado: Debian ${CODENAME}"
info "Iniciando instalación. Log completo en: $LOG"
info "Hora de inicio: $(date)"
echo ""

# ─────────────────────────────────────────────────────────────
# PASO 1 — Repositorios
# ─────────────────────────────────────────────────────────────
step "[1/${TOTAL_STEPS}] Configurando repositorios Debian (${CODENAME})..."

# Repositorio de seguridad: bookworm usa "bookworm-security", trixie igual
SEC_SUITE="${CODENAME}-security"

cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${SEC_SUITE} main contrib non-free non-free-firmware
EOF

# Backports solo si no es sid/trixie rolling
if [[ "$CODENAME" == "bookworm" ]]; then
    echo "deb http://deb.debian.org/debian ${CODENAME}-backports main contrib non-free non-free-firmware" \
        >> /etc/apt/sources.list
fi

apt-get update -qq

# Reparar dependencias rotas antes de instalar nada nuevo
apt-get -f install -y 2>/dev/null || true
apt-get install -y --fix-broken 2>/dev/null || true

apt-get install -y --no-install-recommends \
    curl wget gnupg ca-certificates apt-transport-https \
    sudo ufw avahi-daemon fuse3 net-tools openssh-server \
    lsb-release

ok "Repositorios configurados para Debian ${CODENAME}."

# ─────────────────────────────────────────────────────────────
# PASO 2 — Firmware WiFi
# ─────────────────────────────────────────────────────────────
step "[2/${TOTAL_STEPS}] Instalando drivers WiFi (Intel/Realtek/Atheros/Broadcom/Ralink/MediaTek)..."

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
    2>/dev/null

# Actualizar initramfs para que el firmware cargue al arrancar
update-initramfs -u -k all 2>/dev/null || true

ok "Drivers WiFi instalados."

# ─────────────────────────────────────────────────────────────
# PASO 3 — Jellyfin
# ─────────────────────────────────────────────────────────────
step "[3/${TOTAL_STEPS}] Instalando Jellyfin..."

curl -fsSL https://repo.jellyfin.org/install-jellyfin.sh | bash

ok "Jellyfin instalado."

# ─────────────────────────────────────────────────────────────
# PASO 4 — Carpetas de medios y usuario
# ─────────────────────────────────────────────────────────────
step "[4/${TOTAL_STEPS}] Creando carpetas de medios y usuario del sistema..."

# Crear usuario mediaserver si no existe
if ! id "mediaserver" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,audio,video mediaserver
    echo "mediaserver:jellyfin123" | chpasswd
    info "Usuario 'mediaserver' creado. Contraseña: jellyfin123 (¡cámbiala!)"
fi

# Carpetas de medios
mkdir -p /media/peliculas \
         /media/series \
         /media/musica \
         /media/fotos \
         /media/nube

# Permisos
chown -R mediaserver:mediaserver /media
chmod -R 775 /media

# Jellyfin necesita acceso a las carpetas
usermod -aG mediaserver jellyfin 2>/dev/null || true
usermod -aG video       jellyfin 2>/dev/null || true
usermod -aG render      jellyfin 2>/dev/null || true

ok "Carpetas y usuario configurados."

# ─────────────────────────────────────────────────────────────
# PASO 5 — Filebrowser (subir archivos desde el celular)
# ─────────────────────────────────────────────────────────────
step "[5/${TOTAL_STEPS}] Instalando Filebrowser (subir archivos desde el celular)..."

curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

mkdir -p /etc/filebrowser

/usr/local/bin/filebrowser config init \
    --database /etc/filebrowser/filebrowser.db

/usr/local/bin/filebrowser config set \
    --database /etc/filebrowser/filebrowser.db \
    --address 0.0.0.0 \
    --port 8080 \
    --root /media \
    --log /var/log/filebrowser.log

/usr/local/bin/filebrowser users add admin jellyfin123 \
    --database /etc/filebrowser/filebrowser.db \
    --perm.admin 2>/dev/null || \
/usr/local/bin/filebrowser users update admin \
    --database /etc/filebrowser/filebrowser.db \
    --password jellyfin123 2>/dev/null || true

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

chown -R mediaserver:mediaserver /etc/filebrowser
ok "Filebrowser instalado (puerto 8080)."

# ─────────────────────────────────────────────────────────────
# PASO 6 — Rclone + Box.net
# ─────────────────────────────────────────────────────────────
step "[6/${TOTAL_STEPS}] Instalando Rclone (Box.net como disco local)..."

curl -fsSL https://rclone.org/install.sh | bash

mkdir -p /home/mediaserver/.config/rclone
chown -R mediaserver:mediaserver /home/mediaserver/.config

# Habilitar user_allow_other en FUSE
if ! grep -q "user_allow_other" /etc/fuse.conf 2>/dev/null; then
    echo "user_allow_other" >> /etc/fuse.conf
fi

# Servicio de montaje automático al arrancar
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

# Script de configuración guiada de Box.net
cat > /usr/local/bin/configurar-nube <<'SCRIPT'
#!/bin/bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
RCLONE_CONF="/home/mediaserver/.config/rclone/rclone.conf"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║             CONECTAR BOX.NET AL SERVIDOR                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Este proceso vincula tu cuenta de Box.net usando OAuth2."
echo "  Tu contraseña NUNCA se guarda en el servidor."
echo ""
echo "  Necesitas acceso a un navegador (celular o PC) para"
echo "  autorizar cuando se te pida."
echo ""
read -rp "  Presiona Enter para continuar..." _

# Configurar rclone con Box
sudo -u mediaserver rclone config create nube box \
    --config "$RCLONE_CONF" \
    --non-interactive 2>/dev/null || true

# Autorización OAuth
echo ""
echo "  Paso siguiente: rclone abrirá un enlace."
echo "  Ábrelo en tu navegador e inicia sesión en Box.net."
echo ""
sudo -u mediaserver rclone config reconnect nube: \
    --config "$RCLONE_CONF"

# Verificar conexión
echo ""
echo "  Verificando conexión con Box.net..."
if sudo -u mediaserver rclone lsd nube: --config "$RCLONE_CONF" 2>/dev/null; then
    echo ""
    echo "  ✓ Conexión exitosa!"

    # Crear carpetas en Box si no existen
    for folder in peliculas series musica fotos; do
        sudo -u mediaserver rclone mkdir "nube:/${folder}" \
            --config "$RCLONE_CONF" 2>/dev/null || true
    done

    systemctl enable rclone-nube
    systemctl start  rclone-nube
    echo ""
    echo "  ✓ Box.net montado en: /media/nube"
    echo "  ✓ Se montará automáticamente cada vez que arranque el servidor."
else
    echo ""
    echo "  ✗ No se pudo conectar. Vuelve a intentarlo:"
    echo "    sudo configurar-nube"
fi
SCRIPT

chmod +x /usr/local/bin/configurar-nube
ok "Rclone instalado. Ejecuta 'sudo configurar-nube' para conectar Box.net."

# ─────────────────────────────────────────────────────────────
# PASO 7 — Firewall (UFW)
# ─────────────────────────────────────────────────────────────
step "[7/${TOTAL_STEPS}] Configurando firewall..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 8096/tcp  comment 'Jellyfin HTTP'
ufw allow 8920/tcp  comment 'Jellyfin HTTPS'
ufw allow 8080/tcp  comment 'Filebrowser'
ufw allow 1900/udp  comment 'DLNA/SSDP'
ufw allow 7359/udp  comment 'Jellyfin discovery'
ufw allow 41641/udp comment 'Tailscale'
ufw --force enable

ok "Firewall configurado."

# ─────────────────────────────────────────────────────────────
# PASO 8 — Tailscale (acceso remoto)
# ─────────────────────────────────────────────────────────────
step "[8/${TOTAL_STEPS}] Instalando Tailscale (acceso remoto)..."

curl -fsSL https://tailscale.com/install.sh | sh

systemctl enable tailscaled
systemctl start  tailscaled

# Permitir tráfico desde la interfaz Tailscale
ufw allow in on tailscale0 2>/dev/null || true

# Script de activación
cat > /usr/local/bin/conectar-remoto <<'SCRIPT'
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           ACTIVAR ACCESO REMOTO (TAILSCALE)              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  PASO 1: Instala Tailscale en tu celular o PC:"
echo "    Android/iOS  → busca 'Tailscale' en la tienda de apps"
echo "    Windows/Mac  → https://tailscale.com/download"
echo ""
echo "  PASO 2: Crea cuenta gratis en https://tailscale.com"
echo "          (puedes usar tu cuenta de Google)"
echo ""
echo "  PASO 3: A continuación aparecerá un enlace."
echo "          Ábrelo en el navegador e inicia sesión con"
echo "          la misma cuenta de Tailscale."
echo ""
read -rp "  Presiona Enter para conectar..." _

tailscale up

TS_IP=$(tailscale ip -4 2>/dev/null || echo "pendiente")

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                ¡SERVIDOR CONECTADO!                      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  IP Tailscale: ${TS_IP}"
echo ""
echo "  Desde CUALQUIER lugar con Tailscale activo:"
echo "    Jellyfin:     http://${TS_IP}:8096"
echo "    Filebrowser:  http://${TS_IP}:8080"
echo ""
SCRIPT

chmod +x /usr/local/bin/conectar-remoto
ok "Tailscale instalado. Ejecuta 'sudo conectar-remoto' para activar el acceso remoto."

# ─────────────────────────────────────────────────────────────
# PASO 9 — Habilitar y arrancar servicios
# ─────────────────────────────────────────────────────────────
step "[9/${TOTAL_STEPS}] Activando servicios al arranque..."

systemctl daemon-reload
systemctl enable jellyfin
systemctl enable filebrowser
systemctl enable avahi-daemon
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable ssh

systemctl restart jellyfin    2>/dev/null || true
systemctl restart filebrowser 2>/dev/null || true
systemctl restart avahi-daemon 2>/dev/null || true

ok "Servicios habilitados y arrancados."

# ─────────────────────────────────────────────────────────────
# PASO 10 — Resumen final
# ─────────────────────────────────────────────────────────────
step "[${TOTAL_STEPS}/${TOTAL_STEPS}] Instalación completada"

IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "IP-DEL-SERVIDOR")

echo ""
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       JELLYFIN MEDIA SERVER - LISTO ✓ (${CODENAME})          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "  ── ACCESO EN RED LOCAL ──────────────────────────────────"
echo ""
echo "  Jellyfin (TV/celular):   http://${IP}:8096"
echo "  Filebrowser (subir):     http://${IP}:8080"
echo "  Usuario:  admin          Contraseña: jellyfin123"
echo ""
echo "  ── PRÓXIMOS PASOS ───────────────────────────────────────"
echo ""
echo "  1. Abre Jellyfin en el navegador y agrega tus carpetas:"
echo "       /media/peliculas    /media/series"
echo "       /media/musica       /media/fotos"
echo ""
echo "  2. Conecta Box.net como disco local:"
echo "       sudo configurar-nube"
echo "       (necesitas un navegador para autorizar)"
echo ""
echo "  3. Activa acceso remoto desde cualquier lugar:"
echo "       sudo conectar-remoto"
echo ""
echo "  4. Cambia la contraseña por defecto:"
echo "       passwd mediaserver"
echo ""
echo "  ── DATOS DEL SISTEMA ────────────────────────────────────"
echo ""
echo "  Usuario SSH:     mediaserver   (o el que uses actualmente)"
echo "  Contraseña:      jellyfin123   ← ¡CAMBIALA!"
echo "  Log completo:    $LOG"
echo ""
echo -e "${YELLOW}  WiFi soportado: Intel · Realtek · Atheros · Broadcom · Ralink · MediaTek${NC}"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  Instalación finalizada: $(date)"
echo ""
