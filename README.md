# PocketBase Setup

Script único para desplegar [PocketBase](https://github.com/pocketbase/pocketbase) en Ubuntu como servicio `systemd`, con auto-actualización diaria, superuser inicial y reverse-proxy opcional con HTTPS.

## Qué hace

- Descarga el último release oficial desde GitHub (detecta `amd64` / `arm64` / `armv7`).
- Crea un usuario del sistema dedicado (`pocketbase`, sin shell).
- Instala el binario en `/opt/pocketbase/`.
- Registra un servicio `systemd` con hardening (`ProtectSystem=strict`, `NoNewPrivileges`, etc.).
- Crea el superuser inicial (con password auto-generado si no se especifica).
- Configura un timer `systemd` que ejecuta `pocketbase update` a diario.
- Opcional: configura nginx como reverse proxy + Let's Encrypt (con soporte para Realtime/SSE).
- Opcional: abre los puertos en UFW si está activo.

Es **idempotente** — re-ejecutarlo actualiza el binario sin tocar la base de datos ni el superuser existente.

---

## Requisitos

- Ubuntu (probado en 22.04 / 24.04).
- Acceso `root` o `sudo`.
- Conexión a internet (para descargar el binario y ─ si aplica ─ certbot).

---

## Instalación

### Básica (puerto 8090)

```bash
curl -fsSL https://ews.pe/pocketbase/setup.sh | sudo bash
```

Al terminar imprime las credenciales del superuser inicial:

```
┌─ Superuser inicial ──────────────────────────────
│  Email:     admin@pocketbase.local
│  Password:  Kx7mPq9wRtY2vBn4Lz
└──────────────────────────────────────────────────
```

> El password se genera al azar y solo se muestra una vez. Guárdalo o cámbialo después con el comando que muestra el script.

### Con dominio + HTTPS

```bash
curl -fsSL https://ews.pe/pocketbase/setup.sh | \
    sudo DOMAIN=pb.midominio.com EMAIL=admin@midominio.com bash
```

> El registro DNS A del dominio debe apuntar al servidor **antes** de ejecutar el script (certbot lo necesita para emitir el cert).

### Con credenciales de admin propias

```bash
curl -fsSL https://ews.pe/pocketbase/setup.sh | \
    sudo PB_ADMIN_EMAIL=tu@email.com PB_ADMIN_PASSWORD=MiPassSegura bash
```

---

## Variables de entorno

| Variable            | Default                  | Descripción                                                  |
| ------------------- | ------------------------ | ------------------------------------------------------------ |
| `PB_PORT`           | `8090`                   | Puerto local donde escucha PocketBase.                       |
| `PB_ADMIN_EMAIL`    | `admin@pocketbase.local` | Email del superuser inicial.                                 |
| `PB_ADMIN_PASSWORD` | *(auto-generado)*        | Password del superuser. Si se omite, se genera uno aleatorio. |
| `DOMAIN`            | *(vacío)*                | Si se define, configura nginx + SSL para ese dominio.        |
| `EMAIL`             | *(vacío)*                | Email para Let's Encrypt. Obligatorio si `DOMAIN` está definido. |
| `FORCE`             | *(vacío)*                | `FORCE=1` salta la confirmación interactiva del `uninstall`. |

---

## Estructura instalada

```
/opt/pocketbase/
├── pocketbase            # binario
└── pb_data/              # base de datos SQLite + uploads + logs
    ├── data.db
    ├── auxiliary.db
    ├── logs.db
    ├── storage/
    └── backups/

/etc/systemd/system/
├── pocketbase.service                # servicio principal
├── pocketbase-update.service         # tarea de actualización (oneshot)
└── pocketbase-update.timer           # disparador diario

/usr/local/bin/
└── pocketbase-update                 # script que invoca el timer

# Solo si se usó DOMAIN + EMAIL:
/etc/nginx/sites-available/pocketbase
/etc/nginx/sites-enabled/pocketbase
/etc/letsencrypt/live/<dominio>/
```

---

## Comandos útiles después de instalar

### Servicio

```bash
systemctl status pocketbase           # estado
systemctl restart pocketbase          # reiniciar
systemctl stop pocketbase             # detener
journalctl -u pocketbase -f           # ver logs en vivo
```

### Auto-actualización

```bash
systemctl list-timers pocketbase-update.timer    # próxima ejecución
sudo /usr/local/bin/pocketbase-update            # forzar update ahora
journalctl -u pocketbase-update.service          # historial de updates
```

### Superuser

```bash
# Crear otro superuser
sudo -u pocketbase /opt/pocketbase/pocketbase superuser create otro@email.com Password123

# Cambiar password de uno existente
sudo -u pocketbase /opt/pocketbase/pocketbase superuser update admin@pocketbase.local NuevoPassword

# Listar superusers
sudo -u pocketbase sqlite3 /opt/pocketbase/pb_data/data.db "SELECT email FROM _superusers;"
```

### Backup de la base de datos

```bash
# Backup en caliente vía CLI (recomendado)
sudo -u pocketbase /opt/pocketbase/pocketbase backup nombre-del-backup.zip
# Queda en /opt/pocketbase/pb_data/backups/

# O simple copia del directorio (con el servicio detenido)
sudo systemctl stop pocketbase
sudo tar czf pb_data-$(date +%F).tar.gz -C /opt/pocketbase pb_data
sudo systemctl start pocketbase
```

---

## Acceso al panel admin

- Sin dominio: `http://<IP-del-servidor>:8090/_/`
- Con dominio: `https://<dominio>/_/`

---

## Desinstalación

> **Borrado total**: elimina el binario, la base de datos completa (`pb_data/`), el usuario del sistema, los servicios `systemd`, la configuración nginx y el certificado SSL. **No es reversible.**

### Interactiva (pide confirmación)

```bash
sudo bash setup.sh uninstall
```

Te solicita escribir literalmente `borrar pocketbase` para confirmar.

### Pipeada (no interactiva)

```bash
curl -fsSL https://ews.pe/pocketbase/setup.sh | sudo FORCE=1 bash -s -- uninstall
```

### Lo que NO se elimina

- Reglas de UFW (revísalas con `ufw status`).
- Paquetes APT (`nginx`, `certbot`, `sqlite3`, etc.) por si los usan otros servicios.

---

## Notas importantes

- **PocketBase aún es <1.0.** Las auto-actualizaciones pueden traer cambios incompatibles entre versiones. Si lo usas en producción crítica, considera:
    - Cambiar `OnCalendar=daily` a `weekly` en `/etc/systemd/system/pocketbase-update.timer`, o
    - Desactivar el timer (`systemctl disable --now pocketbase-update.timer`) y actualizar manualmente leyendo el changelog antes.
- El servicio escucha en `0.0.0.0:8090` por defecto. Si **no** usas reverse proxy, asegúrate de tener firewall configurado.
- El timer tiene `RandomizedDelaySec=1h` para evitar que muchos servidores actualicen al mismo segundo.

---

## Repositorio oficial

[pocketbase/pocketbase](https://github.com/pocketbase/pocketbase)
