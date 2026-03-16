#!/bin/bash
# =============================================================================
# NODE INSTALLER — Xray + Hysteria2 + Nginx (фейковая страница логина)
# Один пользователь для VLESS-XHTTP-REALITY + Shadowsocks-2022 + Hysteria2
# Сертификат получает через --webroot (без конфликта с Nginx)
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && log_error "Запускай от root: sudo bash $0"

log_info "=== Установка Xray + Hysteria2 + Nginx (fake login) ==="

# 1. Зависимости
log_info "Установка зависимостей..."
apt update && apt upgrade -y -qq
apt install -y nginx curl wget unzip jq openssl uuid-runtime certbot python3-certbot-nginx cron -qq

# 2. Домен и email
echo ""
log_info "=== Настройка домена и SSL ==="
read -p "Домен для заглушки (например portal.example.com): " DOMAIN
read -p "Email для Let's Encrypt: " EMAIL

[ -z "$DOMAIN" ] || [ -z "$EMAIL" ] && log_error "Домен и email обязательны"

# 3. Создаём фейковую страницу логина
mkdir -p /var/www/fake
cat > /var/www/fake/index.html << 'EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Secure Access</title>
  <style>
    body { margin:0; font-family:Arial,sans-serif; background:#0d1117; color:#c9d1d9; height:100vh; display:flex; align-items:center; justify-content:center; }
    .login-box { background:#161b22; padding:40px; border-radius:8px; width:360px; box-shadow:0 4px 20px rgba(0,0,0,0.5); text-align:center; }
    h2 { margin:0 0 30px; color:#58a6ff; }
    input { width:100%; padding:12px; margin:10px 0; border:1px solid #30363d; border-radius:6px; background:#0d1117; color:#c9d1d9; font-size:16px; }
    button { width:100%; padding:12px; background:#238636; color:white; border:none; border-radius:6px; font-size:16px; cursor:pointer; }
    button:hover { background:#2ea043; }
    .footer { margin-top:30px; font-size:12px; color:#8b949e; }
  </style>
</head>
<body>
  <div class="login-box">
    <h2>Secure Access</h2>
    <form>
      <input type="text" placeholder="Username" required>
      <input type="password" placeholder="Password" required>
      <button type="submit">Sign In</button>
    </form>
    <div class="footer">© 2026 Protected Service</div>
  </div>
</body>
</html>
EOF

chmod -R 755 /var/www/fake

# 4. Временный Nginx только на 80 (для Certbot webroot)
log_info "Запускаем Nginx только на порту 80 для получения сертификата..."
cat > /etc/nginx/sites-available/fake << EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root /var/www/fake;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

ln -sf /etc/nginx/sites-available/fake /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t || log_error "Nginx не прошёл проверку на 80 порту"
systemctl restart nginx || log_error "Не удалось запустить Nginx на 80"

# 5. Получаем сертификат через webroot (Nginx отдаёт challenge-файлы)
log_info "Получаем сертификат через webroot..."
certbot certonly --webroot \
  -w /var/www/fake \
  -d "${DOMAIN}" \
  --email "${EMAIL}" \
  --agree-tos \
  --non-interactive \
  --no-eff-email || log_error "Certbot webroot не сработал. Посмотри: tail -n 50 /var/log/letsencrypt/letsencrypt.log"

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    log_error "Сертификат не найден после certbot"
fi

log_success "Сертификат получен!"

# 6. Добавляем HTTPS в конфиг Nginx
log_info "Добавляем HTTPS в конфиг Nginx..."
cat > /etc/nginx/sites-available/fake << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    root /var/www/fake;
    index index.html;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

nginx -t || log_error "Nginx с HTTPS не прошёл проверку"
systemctl restart nginx || log_error "Не удалось запустить Nginx с HTTPS"

log_success "Nginx + fake login на https://${DOMAIN} готов"

# 7. Установка Xray
log_info "Установка Xray..."
mkdir -p /etc/xray /var/log/xray
XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name | sed 's/v//')
wget -q "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64.zip" -O /tmp/xray.zip
unzip -qo /tmp/xray.zip -d /usr/local/bin/ xray
chmod +x /usr/local/bin/xray
rm -f /tmp/xray.zip

# Reality ключи
xray_keys=$(xray x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$xray_keys" | grep Private | awk '{print $2}')
PUBLIC_KEY=$(echo "$xray_keys" | grep Public | awk '{print $2}')
SHORT_ID=$(openssl rand -hex 8)

# SS server password
SS_SERVER_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 22)

# Настройки Xray
echo ""
log_info "=== Настройки Xray ==="
read -p "SNI для Reality (github.com, www.microsoft.com и т.п.): " SNI
read -p "Path для XHTTP (/ или /api/...): " XHTTP_PATH
read -p "Порт Shadowsocks (8443, 2083 и т.п.): " SS_PORT
while [[ ! "$SS_PORT" =~ ^[0-9]+$ || "$SS_PORT" -lt 1024 || "$SS_PORT" -gt 65535 ]]; do
    log_warning "Порт должен быть 1024–65535"
    read -p "Порт Shadowsocks: " SS_PORT
done

# Пользователь
echo ""
log_info "=== Создаём одного пользователя ==="
read -p "Имя пользователя (a-z0-9_): " USERNAME
[[ ! "$USERNAME" =~ ^[a-zA-Z0-9_]+$ ]] && log_error "Неверное имя"

UUID=$(uuidgen)
HY_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)
SS_USER_PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)

log_success "Пользователь: ${USERNAME}"
log_info "UUID ............ ${UUID}"
log_info "Hysteria2 pass .. ${HY_PASS}"
log_info "SS user pass .... ${SS_USER_PASS}"

# Xray конфиг
cat > /etc/xray/config.json << EOF
{
  "log": {"loglevel": "warning"},
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 4433,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID}", "email": "${USERNAME}"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "publicKey": "${PUBLIC_KEY}",
          "shortIds": ["${SHORT_ID}"]
        },
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "stream-one",
          "xPaddingBytes": "100-800"
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls"]}
    },
    {
      "listen": "0.0.0.0",
      "port": ${SS_PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-256-gcm",
        "password": "${SS_SERVER_PASS}",
        "clients": [{"password": "${SS_USER_PASS}", "email": "${USERNAME}"}]
      }
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ]
}
EOF

cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now xray

# Hysteria2
log_info "Установка Hysteria2..."
HY_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
wget -q "https://github.com/apernet/hysteria/releases/download/${HY_VER}/hysteria-linux-amd64" -O /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

OBFS_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)

mkdir -p /etc/hysteria   # ← вот эта строка решает проблему

cat > /etc/hysteria/config.yaml << EOF
listen: :443

tls:
  cert: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
  key: /etc/letsencrypt/live/${DOMAIN}/privkey.pem

auth:
  type: userpass
  userpass:
    ${USERNAME}: ${HY_PASS}

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASS}

masquerade: https://${DOMAIN}
EOF

# systemd для Hysteria2 (оставь как было)
cat > /etc/systemd/system/hysteria.service << 'EOF'
[Unit]
Description=Hysteria2 Server
After=network.target
[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hysteria

# Сохранение ключей и ссылок
mkdir -p /root/node-keys
IP=$(curl -s4 icanhazip.com || echo "YOUR_IP")

cat > /root/node-keys/credentials.txt << EOF
Пользователь: ${USERNAME}

VLESS:
vless://${UUID}@${IP}:4433?type=xhttp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F#VLESS-XHTTP-REALITY

Shadowsocks:
ss://2022-blake3-aes-256-gcm:${SS_SERVER_PASS}:${SS_USER_PASS}@${IP}:${SS_PORT}#SS-2022-256

Hysteria2:
hysteria2://${USERNAME}:${HY_PASS}@${IP}:443/?insecure=0&sni=${DOMAIN}&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2-${DOMAIN}
EOF

log_success "Установка завершена!"
log_info "Ключи и ссылки сохранены в:"
cat /root/node-keys/credentials.txt

log_info "Рекомендуется перезагрузить сервер: reboot"
