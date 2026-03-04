#!/bin/bash
# ==============================================================
# Jellyfin Mediaserver ISO Builder
# Requisitos: Ubuntu/Debian (GitHub Actions, WSL2, VM o Live USB)
#
# Uso:
#   chmod +x build.sh
#   ./build.sh
#
# Resultado: jellyfin-mediaserver.iso (grabar en USB con Rufus)
# ==============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================
# Colores y funciones  ← SIEMPRE primero
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
# Variables de ISO  ← DESPUÉS de definir funciones
# ==============================================================
BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"

# Obtener el nombre exacto del ISO actual desde SHA256SUMS
# (|| true evita que pipefail falle por el pipe de head)
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
    warn "Instalando paquetes faltantes: ${MISSING[*]}"
    sudo apt-get install -y "${MISSING[@]}" isolinux syslinux-utils 2>/dev/null || \
    sudo apt-get install -y "${MISSING[@]}" 2>/dev/null
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
[[ -f "$INITRD_GZ" ]] \
    || error "No se encontró initrd.gz en la ISO extraída."

info "Desempacando initrd..."
mkdir -p "$WORK_DIR/initrd"
cd "$WORK_DIR/initrd"
gzip -d < "$INITRD_GZ" \
    | cpio --extract --make-directories \
           --no-absolute-filenames \
           --preserve-modification-time 2>/dev/null

info "Copiando preseed.cfg y post-install..."
cp "$SCRIPT_DIR/preseed.cfg"             ./preseed.cfg
cp "$SCRIPT_DIR/scripts/post-install.sh" ./jellyfin-setup.sh
chmod +x ./jellyfin-setup.sh

info "Reempacando initrd..."
find . | cpio -H newc --create 2>/dev/null | gzip -9 > "$INITRD_GZ"
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
readarray -t XORRISO_ARGS < <(
    xorriso -indev "$ISO_ORIG" -report_el_torito as_mkisofs 2>/dev/null \
    | grep -v '^$'
)

info "Empacando ISO..."
xorriso -as mkisofs \
    "${XORRISO_ARGS[@]}" \
    -V "Jellyfin-MediaServer" \
    -o "$ISO_CUSTOM" \
    "$WORK_DIR/iso"

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
