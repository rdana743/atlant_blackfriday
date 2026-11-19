#!/usr/bin/env bash
# Установка huma-leads на VPS (Ubuntu/Debian): Node.js-сервис + nginx + HTTPS (Let's Encrypt).
#
# Запуск на сервере под root:
#   BITRIX_WEBHOOK='https://xxx.bitrix24.ru/rest/1/xxxx/' bash setup.sh
#
# Повторный запуск безопасен: обновит код и конфиг, вебхук и клиентов не сотрёт.
set -euo pipefail

DOMAIN="${DOMAIN:-leads.huma.marketing}"
CLIENT="${CLIENT:-atlant}"
TITLE="${TITLE:-Атлант · Чёрная пятница 11.11}"
ORIGINS="${ORIGINS:-https://rdana743.github.io}"         # через пробел, если сайтов несколько
EMAIL="${EMAIL:-admin@huma.marketing}"                   # для уведомлений Let's Encrypt
REPO_RAW="https://raw.githubusercontent.com/rdana743/atlant_blackfriday/main/server"
APP=/opt/huma-leads; ETC=/etc/huma-leads; DATA=/var/lib/huma-leads; PORT=8787

say(){ printf '\n\033[1;33m▶ %s\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "Запустите под root (sudo -i)"; exit 1; }

say "Проверяю DNS: $DOMAIN"
IP_DNS=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
IP_ME=$(curl -4 -s --max-time 5 https://ifconfig.me || true)
echo "  $DOMAIN → ${IP_DNS:-не найден}; этот сервер → ${IP_ME:-?}"
[ -n "$IP_DNS" ] || { echo "  Добавьте A-запись $DOMAIN → $IP_ME и запустите снова."; exit 1; }

say "Пакеты: nginx, certbot, Node.js"
export DEBIAN_FRONTEND=noninteractive
command -v nginx >/dev/null || { apt-get update -qq; apt-get install -y -qq nginx; }
command -v certbot >/dev/null || { apt-get update -qq; apt-get install -y -qq certbot python3-certbot-nginx; }
NODE_MAJOR=$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || echo 0)
if [ "${NODE_MAJOR:-0}" -lt 18 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs
fi
NODE_BIN=$(command -v node); echo "  node $($NODE_BIN -v)"

say "Код сервиса → $APP"
id huma-leads >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin huma-leads
mkdir -p "$APP" "$ETC" "$DATA"
if [ -f "$(dirname "$0")/server.js" ]; then cp "$(dirname "$0")/server.js" "$APP/server.js"
else curl -fsSL "$REPO_RAW/server.js" -o "$APP/server.js"; fi
chown -R huma-leads:huma-leads "$DATA"; chmod 700 "$DATA"

say "Клиент «$CLIENT» → $ETC/clients.json"
CONF="$ETC/clients.json"; [ -f "$CONF" ] || echo '{}' > "$CONF"
if [ -n "${BITRIX_WEBHOOK:-}" ]; then
  CLIENT="$CLIENT" TITLE="$TITLE" ORIGINS="$ORIGINS" BITRIX_WEBHOOK="$BITRIX_WEBHOOK" CONF="$CONF" "$NODE_BIN" -e '
    const fs=require("fs"),c=JSON.parse(fs.readFileSync(process.env.CONF,"utf8"));
    c[process.env.CLIENT]=Object.assign(c[process.env.CLIENT]||{},{webhook:process.env.BITRIX_WEBHOOK,title:process.env.TITLE,origins:process.env.ORIGINS.split(/\s+/).filter(Boolean)});
    fs.writeFileSync(process.env.CONF,JSON.stringify(c,null,2));'
  echo "  вебхук сохранён"
else
  echo "  BITRIX_WEBHOOK не задан — оставляю текущие настройки"
fi
chown root:huma-leads "$CONF"; chmod 640 "$CONF"

say "systemd-сервис huma-leads"
cat > /etc/systemd/system/huma-leads.service <<EOF
[Unit]
Description=huma-leads: заявки с лендингов → Битрикс24
After=network-online.target
[Service]
User=huma-leads
Environment=PORT=$PORT HOST=127.0.0.1 CLIENTS_FILE=$CONF LOG_DIR=$DATA
ExecStart=$NODE_BIN $APP/server.js
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$DATA
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable -q huma-leads; systemctl restart huma-leads

say "nginx → $DOMAIN"
cat > /etc/nginx/sites-available/huma-leads.conf <<EOF
limit_req_zone \$binary_remote_addr zone=huma_leads:1m rate=30r/m;
server {
  listen 80;
  server_name $DOMAIN;
  client_max_body_size 32k;
  location / {
    limit_req zone=huma_leads burst=10 nodelay;
    proxy_pass http://127.0.0.1:$PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_read_timeout 30s;
  }
}
EOF
ln -sf /etc/nginx/sites-available/huma-leads.conf /etc/nginx/sites-enabled/huma-leads.conf
nginx -t && systemctl reload nginx

say "HTTPS-сертификат Let's Encrypt"
certbot --nginx -n --agree-tos -m "$EMAIL" -d "$DOMAIN" --redirect || echo "  ⚠ certbot не смог выпустить сертификат — проверьте DNS и порт 80"

say "Проверка"
sleep 1
curl -fsS "https://$DOMAIN/health" && echo "  ✓ https://$DOMAIN/$CLIENT готов принимать заявки" || systemctl status huma-leads --no-pager | tail -15
echo
echo "Журнал заявок: $DATA/$CLIENT.jsonl   ·   Логи сервиса: journalctl -u huma-leads -f"
