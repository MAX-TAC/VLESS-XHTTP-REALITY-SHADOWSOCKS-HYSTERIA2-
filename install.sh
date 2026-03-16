#!/bin/bash
# =============================================================================
# INSTALLER — Xray + Hysteria2 + Nginx (фейковая страница логина)
# Один пользователь для VLESS-XHTTP-REALITY + Shadowsocks-2022 + Hysteria2
# Сертификат получает через --webroot
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
apt install -y nginx curl wget unzip jq openssl uuid-runtime certbot python3-certbot-nginx cron ufw -qq

# Открываем порты
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    log_info "Порты 80, 443 TCP/UDP открыты в ufw"
fi

# 2. Домен и email
echo ""
log_info "=== Настройка домена и SSL ==="
read -p "Домен для заглушки (например portal.example.com): " DOMAIN
read -p "Email для Let's Encrypt: " EMAIL

[ -z "$DOMAIN" ] || [ -z "$EMAIL" ] && log_error "Домен и email обязательны"

# 3. Фейковая страница
mkdir -p /var/www/fake
cat > /var/www/fake/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>404 — белые падающие звёзды</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            background-color: #03030a;
            font-family: 'Segoe UI', 'Montserrat', sans-serif;
            height: 100vh;
            overflow: hidden;
            color: white;
        }

        canvas {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            display: block;
            z-index: 1;
            pointer-events: none;
        }

        .content {
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            z-index: 2;
            text-align: center;
            text-shadow: 0 0 20px rgba(255, 255, 255, 0.7);
            pointer-events: none;
        }

        h1 {
            font-size: 15vw;
            font-weight: 800;
            letter-spacing: 0.1em;
            margin: 0;
            line-height: 1;
            background: linear-gradient(45deg, #b0e0ff, #f0f8ff);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            filter: drop-shadow(0 0 25px #7ec8ff);
        }

        p {
            font-size: clamp(1.5rem, 4vw, 2.5rem);
            letter-spacing: 0.5em;
            margin-top: 0.5rem;
            font-weight: 300;
            color: #e6f0ff;
            text-transform: uppercase;
            opacity: 0.9;
            text-shadow: 0 0 15px #a0d0ff;
        }

        .hint {
            position: absolute;
            bottom: 20px;
            left: 0;
            width: 100%;
            text-align: center;
            color: #7a8b9c;
            font-size: 0.9rem;
            z-index: 2;
            letter-spacing: 2px;
            opacity: 0.6;
        }
    </style>
</head>
<body>
    <canvas id="starCanvas"></canvas>
    <div class="content">
        <h1>404</h1>
        <p>Page Not Found</p>
    </div>
    <div class="hint">✨ загадай желание, пока звезда летит</div>

    <script>
        const canvas = document.getElementById('starCanvas');
        const ctx = canvas.getContext('2d');
        let width, height;

        // Звёзды фона
        let stars = [];
        // Падающая звезда
        let shootingStar = null;

        const STARS_COUNT = 200;
        const SHOOTING_STAR_INTERVAL = 5000; // каждые 5 секунд

        // Инициализация звёзд (больше в нижней части)
        function initStars() {
            stars = [];
            for (let i = 0; i < STARS_COUNT; i++) {
                const y = Math.random() < 0.7 
                    ? height * 0.5 + Math.random() * height * 0.5
                    : Math.random() * height * 0.5;
                stars.push({
                    x: Math.random() * width,
                    y: y,
                    radius: Math.random() * 2.5 + 1,
                    brightness: Math.random() * 0.5 + 0.3,
                    speed: Math.random() * 0.02 + 0.005,
                    phase: Math.random() * 2 * Math.PI
                });
            }
        }

        // Создание новой падающей звезды (с улучшенными параметрами)
        function createShootingStar() {
            const startX = Math.random() * width * 0.8 + width * 0.1;
            const startY = Math.random() * height * 0.3;
            const angle = (Math.random() * 30 - 15) * (Math.PI / 180);
            // Увеличенная скорость: 20–30 пикселей за кадр
            const speed = 20 + Math.random() * 10;
            // Укороченный хвост (в 1.5 раза короче предыдущего: теперь 20–33)
            const tailLength = 20 + Math.floor(Math.random() * 14); // от 20 до 33

            shootingStar = {
                x: startX,
                y: startY,
                vx: Math.sin(angle) * speed,
                vy: Math.cos(angle) * speed,
                age: 0,
                maxAge: 80 + Math.floor(Math.random() * 40), // чуть меньше, так как быстрее
                tail: [],
                tailLength: tailLength
            };
        }

        function resizeCanvas() {
            width = window.innerWidth;
            height = window.innerHeight;
            canvas.width = width;
            canvas.height = height;
            initStars();
            shootingStar = null;
        }

        // Отрисовка мерцающих звёзд фона
        function drawStars(time) {
            for (let s of stars) {
                const twinkle = Math.sin(time * s.speed + s.phase) * 0.3 + 0.7;
                const alpha = Math.min(s.brightness * twinkle, 1.0);
                ctx.beginPath();
                ctx.arc(s.x, s.y, s.radius, 0, Math.PI * 2);
                ctx.fillStyle = `rgba(255, 255, 240, ${alpha})`;
                ctx.fill();
            }
        }

        // Отрисовка падающей звезды (чисто белая, тонкая, быстрая)
        function drawShootingStar() {
            if (!shootingStar) return;

            // Добавляем текущую позицию в начало хвоста
            shootingStar.tail.unshift({ x: shootingStar.x, y: shootingStar.y });
            if (shootingStar.tail.length > shootingStar.tailLength) {
                shootingStar.tail.pop();
            }

            // Рисуем хвост как серию соединённых отрезков
            if (shootingStar.tail.length >= 2) {
                ctx.lineCap = 'round';
                ctx.lineJoin = 'round';
                for (let i = 1; i < shootingStar.tail.length; i++) {
                    const p1 = shootingStar.tail[i - 1];
                    const p2 = shootingStar.tail[i];
                    
                    // Коэффициент старения (1 у головы, 0 у конца)
                    const ageFactor = (shootingStar.tail.length - i) / shootingStar.tail.length;
                    
                    // Тонкая линия: толщина от 3 у головы до 0.5 у конца
                    const lineWidth = 3 * ageFactor + 0.5;
                    // Прозрачность от 0.8 до 0
                    const opacity = 0.8 * ageFactor;
                    
                    ctx.beginPath();
                    ctx.moveTo(p1.x, p1.y);
                    ctx.lineTo(p2.x, p2.y);
                    ctx.strokeStyle = `rgba(255, 255, 255, ${opacity})`;
                    ctx.lineWidth = lineWidth;
                    ctx.stroke();
                }
            }

            // Голова звезды (яркая белая точка)
            ctx.beginPath();
            ctx.arc(shootingStar.x, shootingStar.y, 3, 0, Math.PI * 2); // чуть меньше диаметр
            ctx.fillStyle = 'rgba(255, 255, 255, 1)';
            ctx.fill();

            // Перемещение
            shootingStar.x += shootingStar.vx;
            shootingStar.y += shootingStar.vy;
            shootingStar.age++;

            // Удалить, если улетел или состарился
            if (shootingStar.y > height + 100 || shootingStar.x < -100 || shootingStar.x > width + 100 || shootingStar.age > shootingStar.maxAge) {
                shootingStar = null;
            }
        }

        // Анимация
        let lastTimestamp = 0;
        let timeAcc = 0;
        function animate(timestamp) {
            if (!lastTimestamp) lastTimestamp = timestamp;
            const delta = timestamp - lastTimestamp;
            lastTimestamp = timestamp;

            timeAcc += delta;
            if (timeAcc > SHOOTING_STAR_INTERVAL) {
                timeAcc = 0;
                if (!shootingStar) {
                    createShootingStar();
                }
            }

            ctx.clearRect(0, 0, width, height);

            drawStars(timestamp * 0.002);
            drawShootingStar();

            requestAnimationFrame(animate);
        }

        window.addEventListener('resize', () => {
            resizeCanvas();
            timeAcc = 0;
        });

        resizeCanvas();
        setTimeout(() => {
            if (!shootingStar) createShootingStar();
        }, 500);

        requestAnimationFrame(animate);
    </script>
</body>
</html>
EOF

chmod -R 755 /var/www/fake

# 4. Nginx на 80 для Certbot
log_info "Запускаем Nginx только на порту 80..."
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

nginx -t || log_error "Nginx не прошёл проверку на 80"
systemctl restart nginx || log_error "Не удалось запустить Nginx на 80"

# 5. Сертификат
log_info "Получаем сертификат через webroot..."
certbot certonly --webroot \
  -w /var/www/fake \
  -d "${DOMAIN}" \
  --email "${EMAIL}" \
  --agree-tos \
  --non-interactive \
  --no-eff-email || log_error "Certbot ошибка. Лог: tail -n 50 /var/log/letsencrypt/letsencrypt.log"

[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && log_error "Сертификат не найден"

log_success "Сертификат получен!"

# 6. HTTPS в Nginx
log_info "Добавляем HTTPS..."
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

log_success "Nginx готов"

# Установка Xray
log_info "Установка Xray..."
mkdir -p /etc/xray /var/log/xray
XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name | sed 's/v//')
wget -q "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64.zip" -O /tmp/xray.zip
unzip -qo /tmp/xray.zip -d /usr/local/bin/ xray
chmod +x /usr/local/bin/xray
rm -f /tmp/xray.zip

# Скачиваем geoip.dat и geosite.dat (обязательно для routing с geoip:private)
log_info "Скачиваем geoip.dat и geosite.dat..."
mkdir -p /usr/local/share/xray

wget -q -O /usr/local/share/xray/geoip.dat    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
wget -q -O /usr/local/share/xray/geosite.dat  "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

# Reality ключи — берём PrivateKey и Password (pbk = Password)
xray_keys=$(xray x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$xray_keys" | grep -oP 'PrivateKey: \K\S+')
PUBLIC_KEY=$(echo "$xray_keys" | grep -oP 'Password: \K\S+')   # Это и есть pbk
SHORT_ID=$(openssl rand -hex 8)

# Настройки
echo ""
log_info "=== Настройки Xray ==="
read -p "SNI для Reality: " SNI
read -p "Path для XHTTP: " XHTTP_PATH
read -p "Порт Shadowsocks: " SS_PORT
while [[ ! "$SS_PORT" =~ ^[0-9]+$ || "$SS_PORT" -lt 1024 || "$SS_PORT" -gt 65535 ]]; do
    log_warning "Порт 1024–65535"
    read -p "Порт Shadowsocks: " SS_PORT
done

echo ""
log_info "=== Пользователь ==="
read -p "Имя пользователя: " USERNAME
[[ ! "$USERNAME" =~ ^[a-zA-Z0-9_]+$ ]] && log_error "Неверное имя"

UUID=$(uuidgen)
HY_PASS=$(openssl rand -hex 16)

generate_ss_server_pass() {
    local PASS
    while true; do
        PASS=$(openssl rand -base64 32 | tr -d '\n')
        # Проверяем, что нет нежелательных символов
        if [[ "$PASS" != *"/"* && "$PASS" != *"+"* ]]; then
            echo "$PASS"
            return 0
        fi
        # Если попали сюда, значит есть / или + – повторяем цикл
    done
}

SS_SERVER_PASS=$(generate_ss_server_pass)

generate_ss_user_pass() {
    local PASS
    while true; do
        PASS=$(openssl rand -base64 32 | tr -d '\n')
        # Проверяем, что нет нежелательных символов
        if [[ "$PASS" != *"/"* && "$PASS" != *"+"* ]]; then
            echo "$PASS"
            return 0
        fi
        # Если попали сюда, значит есть / или + – повторяем цикл
    done
}

SS_USER_PASS=$(generate_ss_user_pass)

log_success "Пользователь: ${USERNAME}"
log_info "UUID: ${UUID}"
log_info "Hysteria2 pass: ${HY_PASS}"
log_info "SS server pass: ${SS_SERVER_PASS}"
log_info "SS user pass: ${SS_USER_PASS}"

# Xray config
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
Environment="XRAY_LOCATION_ASSET=/usr/local/share/xray"
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now xray

# Установка Hysteria2
log_info "Установка Hysteria2..."
HY_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
wget -q "https://github.com/apernet/hysteria/releases/download/${HY_VER}/hysteria-linux-amd64" -O /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# Определение активного сетевого интерфейса 
log_info "Определение активного сетевого интерфейса..."
ACTIVE_INTERFACE=$(ip -br link | awk '$2 == "UP" && $1 != "lo" {print $1; exit}')
if [ -z "$ACTIVE_INTERFACE" ]; then
    log_warning "Активный сетевой интерфейс не найден, будет использован eth0"
    ACTIVE_INTERFACE="eth0"
else
    log_success "Active interface: $ACTIVE_INTERFACE"
fi

OBFS_PASS=$(openssl rand -hex 16)

mkdir -p /etc/hysteria

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

masquerade:
  type: proxy
  proxy:
    url: https://${DOMAIN}
    insecure: false
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608 
  maxStreamReceiveWindow: 8388608 
  initConnReceiveWindow: 20971520 
  maxConnReceiveWindow: 20971520 
  maxIdleTimeout: 30s 
  maxIncomingStreams: 1024 
  disablePathMTUDiscovery: false

ignoreClientBandwidth: false
  
speedTest: false
disableUDP: false
udpIdleTimeout: 60s

outbounds:
  - name: outbound_direct
    type: direct
    direct:
      mode: auto 
      bindDevice: ${ACTIVE_INTERFACE} 
      fastOpen: false 
EOF

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

# Открываем порт SS
ufw allow "${SS_PORT}"/tcp || true
ufw reload || true

# 9. Ссылки
mkdir -p /root/node-keys
IP=$(curl -s4 icanhazip.com || echo "YOUR_IP")

cat > /root/node-keys/credentials.txt << EOF
Пользователь: ${USERNAME}

VLESS:
vless://${UUID}@${IP}:4433?type=xhttp&encryption=none&path=${XHTTP_PATH}&host=&mode=stream-one&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F#VLESS-XHTTP-REALITY

Shadowsocks:
ss://2022-blake3-aes-256-gcm:${SS_SERVER_PASS}:${SS_USER_PASS}@${IP}:${SS_PORT}?type=tcp#Shadowsocks

Hysteria2:
hysteria2://${USERNAME}:${HY_PASS}@${IP}:443/?insecure=0&sni=${DOMAIN}&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2
EOF

log_success "Установка завершена!"
log_info "Ключи и ссылки:"
cat /root/node-keys/credentials.txt

log_info "Проверьте статус:"
log_info "systemctl status xray"
log_info "systemctl status hysteria"
log_info "reboot рекомендуется"
