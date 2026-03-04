#!/bin/bash
# ==============================================================
# Jellyfin Mediaserver ISO Builder
# Requisitos: Ubuntu/Debian (GitHub Actions, WSL2, VM o Live USB)
# ==============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================
# Colores y funciones  ← definir PRIMERO
# ==============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
title() { echo -e "\n${CYAN}==============================${NC}"; \
          echo -e "${CYAN} $*${NC}"; \
          echo -e "${CYAN}==============================${NC}"; }

WORK_DIR=$(mktemp -d /tmp/iso-build.XXXXXX)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ==============================================================
# Credenciales WiFi
# Prioridad: variables de entorno (GitHub Secrets) > wifi.conf
# ==============================================================
if [[ -f "$SCRIPT_DIR/wifi.conf" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/wifi.conf"
fi

WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
WIFI_SECURITY="${WIFI_SECURITY:-wpa}"

if [[ -z "$WIFI_SSID" || -z "$WIFI_PASSWORD" ]]; then
    error "Faltan credenciales WiFi.\n  Local: copia wifi.conf.example a wifi.conf y edítalo.\n  GitHub Actions: configura los secretos WIFI_SSID y WIFI_PASSWORD."
fi

info "WiFi configurado: SSID='${WIFI_SSID}' / Seguridad=${WIFI_SECURITY}"

# ==============================================================
# Variables de ISO  ← DESPUÉS de definir funciones
# ==============================================================
BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"

ISO_FILENAME=$(wget -qO- "${BASE_URL}/SHA256SUMS" \
    | grep "netinst" | awk '{print $2}' | head -1 || true)

[[ -n "$ISO_FILENAME" ]] \
    || error "No se pudo obtener el listado de ISOs. Revisa la conexión."

ISO_URL="${BASE_URL}/${ISO_FILENAME}"
ISO_ORIG="${SCRIPT_DIR}/${ISO_FILENAME}"
ISO_CUSTOM="${SCRIPT_DIR}/jellyfin-mediaserver.iso"

# ==============================================================
# 1. Dependencias
# ==============================================================
title "Verificando dependencias"

MISSING=()
for cmd in xorriso wget cpio gzip; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "Instalando: ${MISSING[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${MISSING[@]}" isolinux syslinux-utils
fi

info "Dependencias OK"

# ==============================================================
# 2. Descargar ISO base de Debian
# ==============================================================
title "Descargando ISO base"

info "ISO detectada: ${ISO_FILENAME}"

if [[ -f "$ISO_ORIG" ]]; then
    warn "Ya existe ${ISO_FILENAME}, saltando descarga."
else
    info "Descargando ${ISO_FILENAME}..."
    wget --show-progress -O "$ISO_ORIG" "$ISO_URL" \
        || error "No se pudo descargar la ISO desde ${ISO_URL}"
fi

# ==============================================================
# 3. Extraer ISO
# ==============================================================
title "Extrayendo ISO"

mkdir -p "$WORK_DIR/iso"
xorriso -osirrox on -indev "$ISO_ORIG" -extract / "$WORK_DIR/iso" 2>/dev/null
chmod -R u+w "$WORK_DIR/iso"
info "Extraída correctamente"

# ==============================================================
# 4. Inyectar preseed + post-install en el initrd
# ==============================================================
title "Inyectando preseed en initrd"

INITRD_GZ="$WORK_DIR/iso/install.amd/initrd.gz"
[[ -f "$INITRD_GZ" ]] || error "No se encontró initrd.gz en la ISO extraída."

info "Desempacando initrd..."
mkdir -p "$WORK_DIR/initrd"
cd "$WORK_DIR/initrd"

# Desactivar set -e y pipefail: el initrd de Debian 12 es multi-parte
# (microcode + initrd principal concatenados). cpio devuelve exit 2
# al encontrar la segunda parte — es normal, no es un error real.
set +e
set +o pipefail
gzip -d < "$INITRD_GZ" \
    | cpio --extract --make-directories \
           --no-absolute-filenames \
           --preserve-modification-time 2>/dev/null
CPIO_RC=$?
set -e
set -o pipefail

[[ $CPIO_RC -eq 0 || $CPIO_RC -eq 2 ]] \
    || error "Error inesperado al desempacar initrd (código: $CPIO_RC)"

FILE_COUNT=$(find "$WORK_DIR/initrd" -type f | wc -l)
[[ $FILE_COUNT -gt 5 ]] \
    || error "initrd extraído con muy pocos archivos ($FILE_COUNT). Estructura inesperada."

info "initrd desempacado: $FILE_COUNT archivos"

info "Copiando preseed.cfg e inyectando WiFi..."
# Sustituir placeholders con los valores reales de wifi.conf / GitHub Secrets
sed -e "s/__WIFI_SSID__/${WIFI_SSID}/g" \
    -e "s/__WIFI_PASS__/${WIFI_PASSWORD}/g" \
    -e "s/__WIFI_SECURITY__/${WIFI_SECURITY}/g" \
    "$SCRIPT_DIR/preseed.cfg" > ./preseed.cfg

cp "$SCRIPT_DIR/scripts/post-install.sh" ./jellyfin-setup.sh
chmod +x ./jellyfin-setup.sh

info "Reempacando initrd..."
set +e
set +o pipefail
find . | cpio -H newc --create 2>/dev/null | gzip -9 > "$INITRD_GZ"
REPACK_RC=$?
set -e
set -o pipefail

[[ $REPACK_RC -eq 0 ]] || error "Error al reempacar initrd (código: $REPACK_RC)"

cd "$SCRIPT_DIR"

# ==============================================================
# 5. Boot BIOS (isolinux)
# ==============================================================
title "Configurando boot BIOS (isolinux)"

ISOLINUX_TXT="$WORK_DIR/iso/isolinux/txt.cfg"
ISOLINUX_CFG="$WORK_DIR/iso/isolinux/isolinux.cfg"

if [[ -f "$ISOLINUX_TXT" ]]; then
    cat > "$ISOLINUX_TXT" <<'EOF'
default autoinstall
label autoinstall
  menu label Instalar Jellyfin Mediaserver (AUTOMATICO)
  kernel /install.amd/vmlinuz
  append vga=788 initrd=/install.amd/initrd.gz auto=true priority=critical preseed/file=/preseed.cfg --- quiet
label install
  menu label Instalar Debian (Manual)
  kernel /install.amd/vmlinuz
  append vga=788 initrd=/install.amd/initrd.gz --- quiet
EOF
    info "isolinux/txt.cfg configurado"
fi

[[ -f "$ISOLINUX_CFG" ]] && sed -i 's/^timeout .*/timeout 100/' "$ISOLINUX_CFG"

# ==============================================================
# 6. Boot UEFI (GRUB)
# ==============================================================
title "Configurando boot UEFI (GRUB)"

GRUB_CFG="$WORK_DIR/iso/boot/grub/grub.cfg"
if [[ -f "$GRUB_CFG" ]]; then
    cat > "$GRUB_CFG" <<'EOF'
set default=0
set timeout=10

menuentry "Instalar Jellyfin Mediaserver (AUTOMATICO)" {
    set background_color=black
    linux  /install.amd/vmlinuz auto=true priority=critical preseed/file=/preseed.cfg vga=788 --- quiet
    initrd /install.amd/initrd.gz
}

menuentry "Instalar Debian (Manual)" {
    linux  /install.amd/vmlinuz vga=788 --- quiet
    initrd /install.amd/initrd.gz
}
EOF
    info "boot/grub/grub.cfg configurado"
fi

# ==============================================================
# 7. Recalcular checksums MD5
# ==============================================================
title "Recalculando checksums"

pushd "$WORK_DIR/iso" > /dev/null
find . -type f ! -name "md5sum.txt" -exec md5sum {} \; > md5sum.txt
popd > /dev/null
info "md5sum.txt actualizado"

# ==============================================================
# 8. Reempacar ISO
# ==============================================================
title "Construyendo ISO final"

info "Leyendo parámetros de boot del original..."

# IMPORTANTE: xorriso -report_el_torito as_mkisofs emite líneas donde
# una sola línea puede contener DOS opciones separadas por espacio
# (ej: "--grub2-mbr --interval:localfs:..."). readarray las pondría
# como UN solo argumento → xorriso no las parsea.
# Solución: unir en una sola línea y usar bash -c para interpretarlas
# correctamente (bash respeta las comillas simples dentro de la cadena).
XORRISO_CMD=$(xorriso -indev "$ISO_ORIG" -report_el_torito as_mkisofs 2>/dev/null \
    | grep -v '^[[:space:]]*$' \
    | sed "s/-V '[^']*'/-V 'Jellyfin-MediaServer'/" \
    | tr '\n' ' ')

[[ -n "$XORRISO_CMD" ]] || error "No se pudieron obtener los parámetros de boot del ISO original."

info "Construyendo ISO final..."
bash -c "xorriso -as mkisofs ${XORRISO_CMD} -o '${ISO_CUSTOM}' '${WORK_DIR}/iso'" \
    || error "xorriso falló al construir la ISO final."

# ==============================================================
# Resultado
# ==============================================================
ISO_SIZE=$(du -h "$ISO_CUSTOM" | cut -f1)

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  ISO creada exitosamente!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "  Archivo : ${CYAN}${ISO_CUSTOM}${NC}"
echo -e "  Tamaño  : ${ISO_SIZE}"
echo ""
echo -e "${YELLOW}  Grabar en USB (Windows):${NC}"
echo "  Usa Rufus: https://rufus.ie  →  modo 'DD Image'"
echo ""
echo -e "${YELLOW}  Credenciales del servidor:${NC}"
echo "  Usuario    : mediaserver"
echo "  Contraseña : jellyfin123  ← ¡Cambiala después de instalar!"
echo ""
echo -e "${YELLOW}  Tras instalar, accede a:${NC}"
echo "  Jellyfin     → http://IP-DEL-SERVIDOR:8096"
echo "  Filebrowser  → http://IP-DEL-SERVIDOR:8080"
echo ""
echo -e "${YELLOW}  Para conectar Box.net (una sola vez):${NC}"
echo "  sudo configurar-nube"
echo ""
