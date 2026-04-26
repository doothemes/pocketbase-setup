#!/usr/bin/env bash
#
# setup.sh — Despliegue / desinstalación de PocketBase en Ubuntu
#
# Uso (en el servidor):
#     sudo bash setup.sh                    # instalar / actualizar
#     sudo bash setup.sh uninstall          # desinstalar (borrado total)
#
# Opcional, exponer detrás de nginx + Let's Encrypt:
#     sudo DOMAIN=pb.midominio.com EMAIL=admin@midominio.com bash setup.sh
#
# Variables de entorno reconocidas:
#     PB_PORT             Puerto local de PocketBase (default 8090)
#     PB_ADMIN_EMAIL      Email del superuser inicial (default admin@pocketbase.local)
#     PB_ADMIN_PASSWORD   Password del superuser (default: se genera uno aleatorio)
#     DOMAIN              Si se define, configura nginx como reverse proxy + SSL
#     EMAIL               Email para Let's Encrypt (obligatorio si DOMAIN está definido)
#     FORCE=1             Salta la confirmación interactiva del uninstall
#

set -euo pipefail

# ---------- Configuración ----------
PB_USER="pocketbase"
PB_DIR="/opt/pocketbase"
PB_PORT="${PB_PORT:-8090}"
PB_ADMIN_EMAIL="${PB_ADMIN_EMAIL:-admin@pocketbase.local}"
PB_ADMIN_PASSWORD="${PB_ADMIN_PASSWORD:-}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
GENERATED_PASSWORD=0
CREATED_ADMIN=0

# ---------- Helpers ----------
log()  { echo -e "\033[1;34m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Este script debe ejecutarse como root (usa sudo)."
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *) err "Arquitectura no soportada: $(uname -m)"; exit 1 ;;
    esac
}

latest_version() {
    curl -fsSL https://api.github.com/repos/pocketbase/pocketbase/releases/latest \
        | grep -oP '"tag_name":\s*"\K[^"]+' \
        | sed 's/^v//'
}

# ---------- Desinstalación total ----------
do_uninstall() {
    require_root

    warn "ESTA ACCIÓN ELIMINA POR COMPLETO PocketBase, incluyendo:"
    warn "    - El binario y la carpeta ${PB_DIR}/"
    warn "    - La base de datos en ${PB_DIR}/pb_data/  ← ¡no se puede recuperar!"
    warn "    - El usuario del sistema '${PB_USER}'"
    warn "    - Los servicios y timer de systemd"
    warn "    - La configuración nginx + certificado SSL (si existen)"
    echo

    if [[ "${FORCE:-0}" != "1" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Escribe 'borrar pocketbase' para confirmar: " confirmation
            if [[ "$confirmation" != "borrar pocketbase" ]]; then
                err "Cancelado."
                exit 1
            fi
        else
            err "Modo no interactivo: define FORCE=1 para confirmar el borrado."
            err "Ejemplo: curl ... | sudo FORCE=1 bash -s -- uninstall"
            exit 1
        fi
    fi

    log "Deteniendo y deshabilitando servicios..."
    systemctl stop    pocketbase                 2>/dev/null || true
    systemctl stop    pocketbase-update.timer    2>/dev/null || true
    systemctl disable pocketbase                 2>/dev/null || true
    systemctl disable pocketbase-update.timer    2>/dev/null || true

    log "Eliminando unit files de systemd..."
    rm -f /etc/systemd/system/pocketbase.service
    rm -f /etc/systemd/system/pocketbase-update.service
    rm -f /etc/systemd/system/pocketbase-update.timer
    rm -f /usr/local/bin/pocketbase-update
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    # Nginx + cert (solo si los configuró este script)
    if [[ -f /etc/nginx/sites-available/pocketbase ]]; then
        local nginx_domain
        nginx_domain=$(grep -oP 'server_name\s+\K[^;]+' \
            /etc/nginx/sites-available/pocketbase 2>/dev/null \
            | head -1 | tr -d ' ' || true)

        log "Eliminando configuración nginx..."
        rm -f /etc/nginx/sites-enabled/pocketbase
        rm -f /etc/nginx/sites-available/pocketbase
        if command -v nginx &>/dev/null; then
            nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
        fi

        if [[ -n "${nginx_domain:-}" ]] && command -v certbot &>/dev/null; then
            log "Eliminando certificado SSL de ${nginx_domain}..."
            certbot delete --cert-name "$nginx_domain" --non-interactive 2>/dev/null || true
        fi
    fi

    log "Borrando ${PB_DIR}/ (incluye pb_data)..."
    rm -rf "$PB_DIR"

    if id -u "$PB_USER" &>/dev/null; then
        log "Eliminando usuario '${PB_USER}'..."
        userdel "$PB_USER" 2>/dev/null || true
    fi

    echo
    log "PocketBase desinstalado por completo."
    warn "Las reglas de UFW (si se crearon) NO se eliminaron. Revísalas con 'ufw status'."
    exit 0
}

# ---------- Dispatcher ----------
ACTION="${1:-install}"
case "$ACTION" in
    install)   ;; # continúa con el flujo normal
    uninstall) do_uninstall ;;
    *) err "Acción desconocida: '$ACTION' (usa: install | uninstall)"; exit 1 ;;
esac

# ---------- 1. Pre-requisitos ----------
require_root

log "Instalando dependencias del sistema..."
apt-get update -qq
apt-get install -y -qq curl unzip ca-certificates sqlite3 openssl

ARCH=$(detect_arch)
VERSION=$(latest_version)
log "Última versión de PocketBase: v${VERSION} (${ARCH})"

# ---------- 2. Usuario y directorio ----------
if ! id -u "$PB_USER" &>/dev/null; then
    log "Creando usuario del sistema '${PB_USER}'..."
    useradd --system --home-dir "$PB_DIR" --shell /usr/sbin/nologin "$PB_USER"
fi

mkdir -p "$PB_DIR"

# ---------- 3. Descarga del binario ----------
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

ZIP_NAME="pocketbase_${VERSION}_linux_${ARCH}.zip"
DL_URL="https://github.com/pocketbase/pocketbase/releases/download/v${VERSION}/${ZIP_NAME}"

log "Descargando ${ZIP_NAME}..."
curl -fsSL -o "${TMP_DIR}/${ZIP_NAME}" "$DL_URL"

log "Extrayendo binario..."
unzip -o -q "${TMP_DIR}/${ZIP_NAME}" -d "$TMP_DIR"

# Si el servicio ya existe, detenerlo para poder reemplazar el binario
if systemctl is-active --quiet pocketbase 2>/dev/null; then
    log "Deteniendo servicio existente..."
    systemctl stop pocketbase
fi

install -o "$PB_USER" -g "$PB_USER" -m 755 \
    "${TMP_DIR}/pocketbase" "${PB_DIR}/pocketbase"
chown -R "$PB_USER:$PB_USER" "$PB_DIR"

# ---------- 3.5 Superuser inicial ----------
# Solo creamos uno si todavía no existe ningún superuser en la BD.
HAS_SUPERUSER=0
if [[ -f "${PB_DIR}/pb_data/data.db" ]]; then
    HAS_SUPERUSER=$(sudo -u "$PB_USER" sqlite3 "${PB_DIR}/pb_data/data.db" \
        "SELECT COUNT(*) FROM _superusers;" 2>/dev/null || echo 0)
fi

if [[ "$HAS_SUPERUSER" -eq 0 ]]; then
    if [[ -z "$PB_ADMIN_PASSWORD" ]]; then
        PB_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)
        GENERATED_PASSWORD=1
    fi

    log "Creando superuser inicial (${PB_ADMIN_EMAIL})..."
    sudo -u "$PB_USER" "${PB_DIR}/pocketbase" superuser create \
        "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" >/dev/null
    CREATED_ADMIN=1
else
    log "Ya existe un superuser, omitiendo creación."
fi

# ---------- 4. Servicio systemd ----------
log "Configurando servicio systemd..."
cat > /etc/systemd/system/pocketbase.service <<EOF
[Unit]
Description=PocketBase
After=network.target

[Service]
Type=simple
User=${PB_USER}
Group=${PB_USER}
WorkingDirectory=${PB_DIR}
ExecStart=${PB_DIR}/pocketbase serve --http=0.0.0.0:${PB_PORT}
Restart=always
RestartSec=5s
LimitNOFILE=4096

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${PB_DIR}

[Install]
WantedBy=multi-user.target
EOF

# ---------- 5. Auto-actualización (timer systemd) ----------
log "Configurando auto-actualización diaria..."

cat > /usr/local/bin/pocketbase-update <<'EOF'
#!/usr/bin/env bash
# Actualiza PocketBase usando su comando interno y reinicia el servicio.
set -euo pipefail
systemctl stop pocketbase
sudo -u pocketbase /opt/pocketbase/pocketbase update
systemctl start pocketbase
EOF
chmod +x /usr/local/bin/pocketbase-update

cat > /etc/systemd/system/pocketbase-update.service <<EOF
[Unit]
Description=Auto-actualización de PocketBase
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pocketbase-update
EOF

cat > /etc/systemd/system/pocketbase-update.timer <<EOF
[Unit]
Description=Disparador diario para auto-actualizar PocketBase

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ---------- 6. Activar todo ----------
systemctl daemon-reload
systemctl enable --now pocketbase.service
systemctl enable --now pocketbase-update.timer

# ---------- 7. Firewall (si UFW está activo) ----------
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    if [[ -n "$DOMAIN" ]]; then
        log "UFW activo: abriendo 80/443 (HTTP/HTTPS)..."
        ufw allow 80/tcp  >/dev/null
        ufw allow 443/tcp >/dev/null
    else
        log "UFW activo: abriendo puerto ${PB_PORT}..."
        ufw allow "${PB_PORT}/tcp" >/dev/null
    fi
fi

# ---------- 8. (Opcional) Nginx + Let's Encrypt ----------
if [[ -n "$DOMAIN" ]]; then
    if [[ -z "$EMAIL" ]]; then
        err "DOMAIN está definido pero EMAIL no. Define EMAIL=tu@correo.com"
        exit 1
    fi

    log "Instalando nginx + certbot para ${DOMAIN}..."
    apt-get install -y -qq nginx certbot python3-certbot-nginx

    cat > /etc/nginx/sites-available/pocketbase <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:${PB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Soporte para PocketBase Realtime (SSE)
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 24h;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/pocketbase /etc/nginx/sites-enabled/pocketbase
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx

    log "Solicitando certificado SSL..."
    certbot --nginx -d "$DOMAIN" \
        --non-interactive --agree-tos --redirect \
        -m "$EMAIL"
fi

# ---------- 9. Resumen ----------
echo
log "Instalación completada."
echo
echo "    Versión:      v${VERSION}"
echo "    Binario:      ${PB_DIR}/pocketbase"
echo "    Datos:        ${PB_DIR}/pb_data/"
echo "    Servicio:     systemctl status pocketbase"
echo "    Auto-update:  systemctl list-timers pocketbase-update.timer"

if [[ -n "$DOMAIN" ]]; then
    echo "    Admin UI:     https://${DOMAIN}/_/"
else
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "    Admin UI:     http://${IP:-<IP-del-servidor>}:${PB_PORT}/_/"
fi

if [[ "$CREATED_ADMIN" -eq 1 ]]; then
    echo
    echo "    ┌─ Superuser inicial ──────────────────────────────"
    echo "    │  Email:     ${PB_ADMIN_EMAIL}"
    echo "    │  Password:  ${PB_ADMIN_PASSWORD}"
    echo "    └──────────────────────────────────────────────────"
    if [[ "$GENERATED_PASSWORD" -eq 1 ]]; then
        echo
        warn "El password se generó automáticamente. Guárdalo AHORA — no se vuelve a mostrar."
        warn "Cámbialo después con:"
        warn "    sudo -u ${PB_USER} ${PB_DIR}/pocketbase superuser update ${PB_ADMIN_EMAIL} <nuevo-password>"
    fi
fi

echo
warn "PocketBase aún es <1.0; las auto-actualizaciones pueden traer cambios"
warn "incompatibles. Revisa el changelog si vas a usarlo en producción crítica."
