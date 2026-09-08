#!/bin/bash
# ============================================================
# Raspberry Pi Cloud NAS Setup Script
# Installs: Nextcloud + Samba + USB Auto-mount + Tailscale
# Target: Raspberry Pi OS 64-bit (Bookworm)
# Usage: curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/pi-nas/main/setup.sh | sudo bash
# ============================================================

set -e

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[NAS]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---- Must run as root ----
[ "$EUID" -ne 0 ] && error "Please run with sudo"

# ---- Variables ----
NAS_USER=${SUDO_USER:-pi}
NAS_DIR="/home/$NAS_USER/nas"
USB_MOUNT="/media/$NAS_USER"
NC_ADMIN="admin"
NC_PASS="NasAdmin@1234"
DB_NAME="nextcloud"
DB_USER="ncuser"
DB_PASS="ncpass1234"

# ============================================================
# STEP 1 — System prep
# ============================================================
log "Step 1: Updating system..."
apt update && apt upgrade -y
apt install -y curl wget git udiskie udisks2 \
    apache2 mariadb-server \
    php php-gd php-curl php-zip php-xml \
    php-mbstring php-intl php-bcmath \
    php-mysql php-imagick php-redis \
    libapache2-mod-php redis-server \
    samba avahi-daemon

# ============================================================
# STEP 2 — Keyboard layout US
# ============================================================
log "Step 2: Setting keyboard to US..."
sed -i 's/XKBLAYOUT=.*/XKBLAYOUT="us"/' /etc/default/keyboard
setupcon --force 2>/dev/null || true

# ============================================================
# STEP 3 — Fix libarmmem spam
# ============================================================
log "Step 3: Fixing libarmmem preload errors..."
if [ -f /etc/ld.so.preload ]; then
    sed -i 's|^/usr/lib/arm-linux-gnueabihf/libarmmem|#/usr/lib/arm-linux-gnueabihf/libarmmem|' /etc/ld.so.preload
fi

# ============================================================
# STEP 4 — Download & install Nextcloud
# ============================================================
log "Step 4: Downloading Nextcloud..."
cd /tmp
wget -q --show-progress https://download.nextcloud.com/server/releases/latest.tar.bz2
tar -xjf latest.tar.bz2
rm -rf /var/www/html/nextcloud
mv nextcloud /var/www/html/
chown -R www-data:www-data /var/www/html/nextcloud
chmod -R 755 /var/www/html/nextcloud

# ============================================================
# STEP 5 — Database setup
# ============================================================
log "Step 5: Setting up database..."
systemctl enable mariadb && systemctl start mariadb
mysql -u root <<EOF
DROP DATABASE IF EXISTS $DB_NAME;
CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
DROP USER IF EXISTS '$DB_USER'@'localhost';
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# ============================================================
# STEP 6 — Apache config
# ============================================================
log "Step 6: Configuring Apache..."
a2enmod rewrite headers env dir mime ssl
cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    DocumentRoot /var/www/html/nextcloud
    ServerName $(hostname -I | awk '{print $1}')

    <Directory /var/www/html/nextcloud>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </IfModule>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

a2ensite nextcloud.conf
a2dissite 000-default.conf 2>/dev/null || true
systemctl enable apache2 && systemctl restart apache2

# ============================================================
# STEP 7 — Install Nextcloud via CLI
# ============================================================
log "Step 7: Installing Nextcloud (this takes a few minutes)..."
IP=$(hostname -I | awk '{print $1}')
mkdir -p $NAS_DIR
chown -R www-data:www-data $NAS_DIR

sudo -u www-data php /var/www/html/nextcloud/occ maintenance:install \
    --database "mysql" \
    --database-name "$DB_NAME" \
    --database-user "$DB_USER" \
    --database-pass "$DB_PASS" \
    --admin-user "$NC_ADMIN" \
    --admin-pass "$NC_PASS" \
    --data-dir "$NAS_DIR"

# Trusted domain
sudo -u www-data php /var/www/html/nextcloud/occ \
    config:system:set trusted_domains 0 --value="$IP"

# Redis cache
sudo -u www-data php /var/www/html/nextcloud/occ \
    config:system:set memcache.local --value='\OC\Memcache\Redis'
sudo -u www-data php /var/www/html/nextcloud/occ \
    config:system:set redis host --value="localhost"
sudo -u www-data php /var/www/html/nextcloud/occ \
    config:system:set redis port --value=6379 --type=integer

# Phone region
sudo -u www-data php /var/www/html/nextcloud/occ \
    config:system:set default_phone_region --value="IN"

# Enable external storage app
sudo -u www-data php /var/www/html/nextcloud/occ app:enable files_external

# ============================================================
# STEP 8 — USB Auto-mount
# ============================================================
log "Step 8: Setting up USB auto-mount..."
mkdir -p $USB_MOUNT
chown $NAS_USER:$NAS_USER $USB_MOUNT

cat > /etc/systemd/system/udiskie.service <<EOF
[Unit]
Description=Auto-mount USB drives
After=multi-user.target

[Service]
Type=simple
User=$NAS_USER
ExecStart=/usr/bin/udiskie --no-tray --automount
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable udiskie
systemctl start udiskie

# ============================================================
# STEP 9 — Samba share
# ============================================================
log "Step 9: Configuring Samba..."
cat >> /etc/samba/smb.conf <<EOF

[NAS]
   path = $NAS_DIR
   browseable = yes
   read only = no
   valid users = $NAS_USER

[USB]
   path = $USB_MOUNT
   browseable = yes
   read only = no
   valid users = $NAS_USER
   follow symlinks = yes
EOF

systemctl enable smbd && systemctl restart smbd

# ============================================================
# STEP 10 — Nextcloud cron job
# ============================================================
log "Step 10: Setting up Nextcloud cron..."
(crontab -u www-data -l 2>/dev/null; echo "*/5 * * * * php /var/www/html/nextcloud/cron.php") | crontab -u www-data -

# ============================================================
# STEP 11 — Tailscale (optional remote access)
# ============================================================
log "Step 11: Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
warn "Run 'sudo tailscale up' after setup to enable remote access"

# ============================================================
# DONE
# ============================================================
IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   Raspberry Pi Cloud NAS Setup Complete!  ${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  Nextcloud URL : ${YELLOW}http://$IP${NC}"
echo -e "  Admin user    : ${YELLOW}$NC_ADMIN${NC}"
echo -e "  Admin pass    : ${YELLOW}$NC_PASS${NC}"
echo ""
echo -e "  Samba share   : ${YELLOW}\\\\$IP\\NAS${NC}"
echo -e "  Samba user    : ${YELLOW}$NAS_USER${NC}"
echo -e "  Set Samba pass: ${YELLOW}sudo smbpasswd -a $NAS_USER${NC}"
echo ""
echo -e "  USB drives auto-mount to: ${YELLOW}$USB_MOUNT${NC}"
echo ""
echo -e "  For remote access: ${YELLOW}sudo tailscale up${NC}"
echo -e "${GREEN}============================================${NC}"
