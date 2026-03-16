#!/bin/bash
# =============================================================================
# Установщик Xray + Hysteria2 + Nginx (фейковая страница)
# Модернизированная версия: тихий режим, информативный вывод, отказоустойчивость
# =============================================================================

set -eEuo pipefail
trap 'cleanup_on_error $? $LINENO' ERR

# ----------------------------- Цвета и функции вывода -------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Символы
CHECK_MARK="✔"
CROSS_MARK="✗"
ARROW="➜"
CLOCK="⏳"

# Логирование
LOG_FILE="/var/log/vpn-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[${CHECK_MARK} SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[! WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[${CROSS_MARK} ERROR]${NC} $1"; exit 1; }
log_stage()   { echo -e "\n${MAGENTA}════════════════════════════════════════════════════════════${NC}"; echo -e "${WHITE}   $1${NC}"; echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}\n"; }

# ----------------------------- Переменные для отката -------------------------
BACKUP_DIR="/root/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
INSTALL_STEPS=()          # Массив выполненных шагов для отката
DOMAIN=""
EMAIL="dummy@example.com" # Заглушка, не используется

# ----------------------------- Функция отката при ошибке ---------------------
cleanup_on_error() {
    local exit_code=$1
    local line_no=$2
    log_warning "Скрипт прерван на строке $line_no с кодом $exit_code. Запуск отката..."

    # Откат в обратном порядке
    for step in "${INSTALL_STEPS[@]}"; do
        case $step in
            "deps")
                log_info "Удаление установленных пакетов (это может быть неполным)..."
                apt remove --purge -y nginx certbot python3-certbot-nginx &>/dev/null || true
                ;;
            "nginx_fake")
                log_info "Восстановление конфигурации Nginx..."
                if [[ -f "${BACKUP_DIR}/nginx_default.bak" ]]; then
                    cp "${BACKUP_DIR}/nginx_default.bak" /etc/nginx/sites-enabled/default 2>/dev/null || true
                fi
                rm -f /etc/nginx/sites-available/fake /etc/nginx/sites-enabled/fake 2>/dev/null || true
                systemctl restart nginx 2>/dev/null || true
                ;;
            "cert")
                log_info "Удаление сертификата Let's Encrypt..."
                certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null || true
                ;;
            "xray")
                log_info "Остановка и удаление Xray..."
                systemctl stop xray 2>/dev/null || true
                systemctl disable xray 2>/dev/null || true
                rm -f /usr/local/bin/xray /etc/systemd/system/xray.service 2>/dev/null || true
                rm -rf /etc/xray /var/log/xray /usr/local/share/xray 2>/dev/null || true
                systemctl daemon-reload 2>/dev/null || true
                ;;
            "hysteria")
                log_info "Остановка и удаление Hysteria..."
                systemctl stop hysteria 2>/dev/null || true
                systemctl disable hysteria 2>/dev/null || true
                rm -f /usr/local/bin/hysteria /etc/systemd/system/hysteria.service 2>/dev/null || true
                rm -rf /etc/hysteria 2>/dev/null || true
                systemctl daemon-reload 2>/dev/null || true
                ;;
        esac
    done
    log_warning "Откат завершён. Проверьте систему вручную."
    exit $exit_code
}

# ----------------------------- Проверка прав и зависимостей ------------------
check_prerequisites() {
    log_stage "ПРОВЕРКА СИСТЕМЫ"
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от root. Используйте: sudo bash $0"
    fi

    local needed_commands=("curl" "wget" "systemctl" "ufw" "openssl" "uuidgen" "jq")
    local missing=()
    for cmd in "${needed_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warning "Отсутствуют команды: ${missing[*]}. Попытка установить..."
        apt update -qq &>/dev/null || log_error "apt update не удался"
        apt install -y -qq "${missing[@]}" &>/dev/null || log_error "Не удалось установить недостающие пакеты: ${missing[*]}"
        log_success "Зависимости доустановлены"
    else
        log_success "Все необходимые команды доступны"
    fi
}

# ----------------------------- Выбор домена (свой или DuckDNS) ----------------
choose_domain() {
    log_stage "НАСТРОЙКА ДОМЕНА"
    echo -e "${ARROW} Введите ваш домен, который уже указывает на IP этого сервера."
    echo -e "   Например: vpn.example.com или portal.example.com"
    read -p "Домен: " DOMAIN

    if [[ -z "$DOMAIN" ]]; then
        log_error "Домен не может быть пустым"
    fi
    # Простейшая проверка формата домена
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Неверный формат домена"
    fi
    # Проверка резолвинга (опционально)
    if ! getent hosts "$DOMAIN" &>/dev/null; then
        log_warning "Домен $DOMAIN не резолвится. Убедитесь, что DNS запись настроена и распространилась."
    else
        log_success "Домен $DOMAIN резолвится корректно"
    fi
}

# ----------------------------- Определение активного сетевого интерфейса -----
detect_interface() {
    log_stage "ОПРЕДЕЛЕНИЕ СЕТЕВОГО ИНТЕРФЕЙСА"
    local interfaces=($(ip -br link | awk '$2 == "UP" && $1 != "lo" {print $1}'))
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_warning "Активные интерфейсы не найдены, используется eth0"
        ACTIVE_INTERFACE="eth0"
    elif [[ ${#interfaces[@]} -eq 1 ]]; then
        ACTIVE_INTERFACE="${interfaces[0]}"
        log_success "Найден интерфейс: $ACTIVE_INTERFACE"
    else
        echo -e "${ARROW} Найдено несколько активных интерфейсов:"
        select IF in "${interfaces[@]}"; do
            if [[ -n "$IF" ]]; then
                ACTIVE_INTERFACE="$IF"
                log_success "Выбран интерфейс: $ACTIVE_INTERFACE"
                break
            else
                log_warning "Неверный выбор, попробуйте снова"
            fi
        done
    fi
}

# ----------------------------- Установка зависимостей -------------------------
install_deps() {
    log_stage "УСТАНОВКА ЗАВИСИМОСТЕЙ"
    log_info "Обновление списка пакетов и установка необходимого ПО..."
    apt update -qq &>/dev/null || log_error "apt update не удался"
    apt upgrade -y -qq &>/dev/null || log_warning "apt upgrade пропущен"
    apt install -y -qq nginx curl wget unzip jq openssl uuid-runtime certbot python3-certbot-nginx cron ufw &>/dev/null || log_error "Не удалось установить базовые пакеты"
    log_success "Зависимости установлены"

    # Открытие портов в ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        log_info "Настройка UFW: открываем порты 80, 443 TCP/UDP"
        ufw allow 80/tcp &>/dev/null
        ufw allow 443/tcp &>/dev/null
        ufw allow 443/udp &>/dev/null
        log_success "Порты открыты"
    fi
    INSTALL_STEPS+=("deps")
}

# ----------------------------- Настройка Nginx (фейковая страница) -----------
setup_nginx() {
    log_stage "НАСТРОЙКА NGINX (ФЕЙКОВАЯ СТРАНИЦА)"
    log_info "Создание директории /var/www/fake"
    mkdir -p /var/www/fake

    # Минимальная заглушка 
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

    # Резервное копирование существующего default
    if [[ -f /etc/nginx/sites-enabled/default ]]; then
        cp /etc/nginx/sites-enabled/default "${BACKUP_DIR}/nginx_default.bak"
    fi

    log_info "Создание конфигурации Nginx (порт 80)..."
    cat > /etc/nginx/sites-available/fake << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root /var/www/fake;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF

    ln -sf /etc/nginx/sites-available/fake /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    nginx -t &>/dev/null || log_error "Конфигурация Nginx (порт 80) не прошла проверку"
    systemctl restart nginx &>/dev/null || log_error "Не удалось запустить Nginx"
    log_success "Nginx слушает порт 80"
    INSTALL_STEPS+=("nginx_fake")
}

# ----------------------------- Получение SSL-сертификата ---------------------
get_certificate() {
    log_stage "ПОЛУЧЕНИЕ SSL-СЕРТИФИКАТА LET'S ENCRYPT"
    log_info "Запуск certbot через webroot..."
    certbot certonly --webroot -w /var/www/fake -d "$DOMAIN" \
        --email "$EMAIL" --agree-tos --non-interactive --no-eff-email \
        &>/dev/null || log_error "Ошибка получения сертификата. Проверьте лог: $LOG_FILE"

    if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        log_error "Сертификат не найден после получения"
    fi
    log_success "Сертификат получен"

    # Настройка HTTPS в Nginx
    log_info "Добавление HTTPS в конфигурацию Nginx"
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
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF

    nginx -t &>/dev/null || log_error "Конфигурация HTTPS не прошла проверку"
    systemctl restart nginx &>/dev/null || log_error "Не удалось перезапустить Nginx"
    log_success "Nginx теперь обслуживает HTTPS"

    # Настройка автообновления сертификата
    if systemctl list-unit-files | grep -q certbot.timer; then
        systemctl enable certbot.timer &>/dev/null
        systemctl start certbot.timer &>/dev/null
        log_success "Автообновление сертификата настроено (certbot.timer)"
    else
        log_warning "certbot.timer не найден, добавьте задачу в cron вручную: 0 0 * * * /usr/bin/certbot renew --quiet"
    fi
    INSTALL_STEPS+=("cert")
}

# ----------------------------- Установка Xray ---------------------------------
install_xray() {
    log_stage "УСТАНОВКА XRAY"
    log_info "Создание директорий..."
    mkdir -p /etc/xray /var/log/xray /usr/local/share/xray

    log_info "Определение последней версии Xray..."
    XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name | sed 's/v//') || log_error "Не удалось получить версию Xray"
    log_success "Версия: $XRAY_VER"

    log_info "Загрузка Xray-core..."
    wget -q --show-progress "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-64.zip" -O /tmp/xray.zip || log_error "Ошибка загрузки Xray"
    log_info "Распаковка..."
    unzip -qo /tmp/xray.zip -d /usr/local/bin/ xray || log_error "Ошибка распаковки Xray"
    chmod +x /usr/local/bin/xray
    rm -f /tmp/xray.zip
    log_success "Xray установлен"

    log_info "Загрузка геоданных (geoip.dat, geosite.dat)..."
    wget -q -O /usr/local/share/xray/geoip.dat    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" || log_warning "Не удалось загрузить geoip.dat"
    wget -q -O /usr/local/share/xray/geosite.dat  "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" || log_warning "Не удалось загрузить geosite.dat"

    # Генерация ключей Reality
    log_info "Генерация ключей Reality..."
    xray_keys=$(/usr/local/bin/xray x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$xray_keys" | grep -oP 'PrivateKey: \K\S+')
    PUBLIC_KEY=$(echo "$xray_keys" | grep -oP 'Password: \K\S+')
    SHORT_ID=$(openssl rand -hex 8)
    log_success "Ключи сгенерированы"

    # Ввод параметров пользователем
    echo ""
    read -p "SNI для Reality (например, www.microsoft.com): " SNI
    read -p "Path для XHTTP (начинается с /, например /xhttp): " XHTTP_PATH
    if [[ ! "$XHTTP_PATH" =~ ^/ ]]; then
        log_error "Path должен начинаться с /"
    fi
    read -p "Порт Shadowsocks (1024-65535): " SS_PORT
    while [[ ! "$SS_PORT" =~ ^[0-9]+$ || "$SS_PORT" -lt 1024 || "$SS_PORT" -gt 65535 ]]; do
        log_warning "Порт должен быть в диапазоне 1024–65535"
        read -p "Порт Shadowsocks: " SS_PORT
    done
    # Проверка, что порт не занят
    if ss -tuln | grep -q ":${SS_PORT} "; then
        log_error "Порт $SS_PORT уже занят"
    fi

    echo ""
    read -p "Имя пользователя (только латиница, цифры, _): " USERNAME
    if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Неверное имя пользователя"
    fi

    UUID=$(uuidgen)
    HY_PASS=$(openssl rand -hex 16)

    generate_ss_pass() {
        local PASS
        while true; do
            PASS=$(openssl rand -base64 32 | tr -d '\n')
            if [[ "$PASS" != *"/"* && "$PASS" != *"+"* ]]; then
                echo "$PASS"
                return 0
            fi
        done
    }
    SS_SERVER_PASS=$(generate_ss_pass)
    SS_USER_PASS=$(generate_ss_pass)

    log_success "Параметры пользователя сгенерированы"

    # Конфиг Xray
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

    # systemd unit
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

    systemctl daemon-reload &>/dev/null
    systemctl enable --now xray &>/dev/null || log_error "Не удалось запустить Xray"
    log_success "Xray запущен"
    INSTALL_STEPS+=("xray")

    # Открыть порт SS в ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${SS_PORT}"/tcp &>/dev/null
        log_info "Порт $SS_PORT TCP открыт в ufw"
    fi
}

# ----------------------------- Установка Hysteria2 ---------------------------
install_hysteria() {
    log_stage "УСТАНОВКА HYSTERIA2"
    log_info "Определение последней версии Hysteria..."
    HY_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name) || log_error "Не удалось получить версию Hysteria"
    log_success "Версия: $HY_VER"

    log_info "Загрузка Hysteria..."
    wget -q --show-progress "https://github.com/apernet/hysteria/releases/download/${HY_VER}/hysteria-linux-amd64" -O /usr/local/bin/hysteria || log_error "Ошибка загрузки Hysteria"
    chmod +x /usr/local/bin/hysteria
    log_success "Hysteria загружен"

    # Интерфейс уже определён в detect_interface
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

    systemctl daemon-reload &>/dev/null
    systemctl enable --now hysteria &>/dev/null || log_error "Не удалось запустить Hysteria"
    log_success "Hysteria запущен"
    INSTALL_STEPS+=("hysteria")
}

# ----------------------------- Вывод результатов -----------------------------
show_results() {
    log_stage "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО"
    mkdir -p /root/node-keys
    IP=$(curl -s4 ifconfig.me || echo "YOUR_IP")

    cat > /root/node-keys/credentials.txt << EOF
Пользователь: ${USERNAME}

VLESS:
vless://${UUID}@${IP}:4433?type=xhttp&encryption=none&path=${XHTTP_PATH}&host=&mode=stream-one&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F#VLESS-XHTTP-REALITY

Shadowsocks:
ss://2022-blake3-aes-256-gcm:${SS_SERVER_PASS}:${SS_USER_PASS}@${IP}:${SS_PORT}?type=tcp#Shadowsocks

Hysteria2:
hysteria2://${USERNAME}:${HY_PASS}@${IP}:443/?insecure=0&sni=${DOMAIN}&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2
EOF

    # Красивый вывод в рамке
    local box_width=70
    print_line() { printf "${GREEN}│${NC} %-${box_width}s ${GREEN}│${NC}\n" "$1"; }
    echo -e "${GREEN}┌─$(printf '─%.0s' $(seq 1 $box_width))─┐${NC}"
    print_line "⚡ Ссылки и ключи сохранены в /root/node-keys/credentials.txt"
    print_line ""
    print_line "VLESS:     vless://... (смотри в файле)"
    print_line "Shadowsocks: ss://... (смотри в файле)"
    print_line "Hysteria2:  hysteria2://... (смотри в файле)"
    print_line ""
    print_line "Проверка статуса служб:"
    print_line "  systemctl status xray"
    print_line "  systemctl status hysteria"
    print_line "  systemctl status nginx"
    print_line ""
    print_line "Лог установки: $LOG_FILE"
    echo -e "${GREEN}└─$(printf '─%.0s' $(seq 1 $box_width))─┘${NC}"

    log_success "Установка завершена! Рекомендуется перезагрузить сервер."
}

# ----------------------------- Основная программа ----------------------------
main() {
    check_prerequisites
    choose_domain
    detect_interface
    install_deps
    setup_nginx
    get_certificate
    install_xray
    install_hysteria
    show_results
}

main "$@"
