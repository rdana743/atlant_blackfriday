#!/usr/bin/env bash
# Установка лендинга + приёмника заявок на VPS (Ubuntu/Debian).
#
#   SITE_DOMAIN=stomat.shop BITRIX_WEBHOOK='https://xxx.bitrix24.ru/rest/1/xxxx/' bash setup.sh
#
# Что делает:
#   • сайт: клонирует репозиторий в /var/www/<домен> и раз в 2 минуты подтягивает изменения из GitHub
#     (пуш в main → через ≤2 мин изменения на сайте);
#   • заявки: сервис huma-leads (Node.js) на /api/lead/<клиент> → лид в Битрикс24;
#   • nginx + HTTPS (Let's Encrypt), www → без www, сжатие и кэш статики.
# Повторный запуск безопасен: обновит код и конфиги, вебхук и журнал заявок не тронет.
set -euo pipefail

SITE_DOMAIN="${SITE_DOMAIN:-stomat.shop}"
CLIENT="${CLIENT:-atlant}"
TITLE="${TITLE:-Атлант · Чёрная пятница}"
ORIGINS="${ORIGINS:-https://$SITE_DOMAIN https://www.$SITE_DOMAIN https://rdana743.github.io}"
EMAIL="${EMAIL:-admin@huma.marketing}"
REPO="${REPO:-https://github.com/rdana743/atlant_blackfriday.git}"
BRANCH="${BRANCH:-main}"
WEB="/var/www/$SITE_DOMAIN"
APP=/opt/huma-leads; ETC=/etc/huma-leads; DATA=/var/lib/huma-leads; PORT=8787

say(){ printf '\n\033[1;33m▶ %s\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "Запустите под root (sudo -i)"; exit 1; }

say "Проверяю DNS"
IP_ME=$(curl -4 -s --max-time 5 https://ifconfig.me || true)
for h in "$SITE_DOMAIN" "www.$SITE_DOMAIN"; do
  ip=$(getent ahostsv4 "$h" | awk 'NR==1{print $1}' || true)
  echo "  $h → ${ip:-нет записи}   (этот сервер: ${IP_ME:-?})"
  [ -n "$ip" ] || { echo "  Добавьте A-запись $h → $IP_ME, подождите 10–30 минут и запустите снова."; exit 1; }
done

say "Пакеты: nginx, certbot, git, Node.js"
export DEBIAN_FRONTEND=noninteractive
need=(); for p in nginx certbot git; do command -v $p >/dev/null || need+=($p); done
if [ ${#need[@]} -gt 0 ]; then
  apt-get update -qq
  pk=(); for p in "${need[@]}"; do [ "$p" = certbot ] && pk+=(certbot python3-certbot-nginx) || pk+=($p); done
  apt-get install -y -qq "${pk[@]}"
fi
NODE_MAJOR=$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || true)
if [ "${NODE_MAJOR:-0}" -lt 18 ] 2>/dev/null || [ -z "$NODE_MAJOR" ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs
fi
NODE_BIN=$(command -v node); echo "  node $($NODE_BIN -v)"

say "Сайт → $WEB"
if [ -d "$WEB/.git" ]; then git -C "$WEB" fetch -q --depth 1 origin "$BRANCH" && git -C "$WEB" reset -q --hard "origin/$BRANCH"
else rm -rf "$WEB"; git clone -q --depth 1 -b "$BRANCH" "$REPO" "$WEB"; fi
chown -R www-data:www-data "$WEB"
cat > /etc/cron.d/site-$SITE_DOMAIN <<EOF
# автообновление сайта из GitHub раз в 2 минуты
*/2 * * * * www-data cd $WEB && git fetch -q --depth 1 origin $BRANCH && [ "\$(git rev-parse HEAD)" != "\$(git rev-parse origin/$BRANCH)" ] && git reset -q --hard origin/$BRANCH
EOF
echo "  ✓ автообновление из GitHub включено"

say "Сервис заявок huma-leads"
id huma-leads >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin huma-leads
mkdir -p "$APP" "$ETC" "$DATA"
if [ -f "$WEB/server/server.js" ]; then cp "$WEB/server/server.js" "$APP/server.js"
else curl -fsSL https://raw.githubusercontent.com/rdana743/atlant_blackfriday/main/server/server.js -o "$APP/server.js"; fi
chown -R huma-leads:huma-leads "$DATA"; chmod 700 "$DATA"
CONF="$ETC/clients.json"; [ -f "$CONF" ] || echo '{}' > "$CONF"
if [ -n "${BITRIX_WEBHOOK:-}" ]; then
  CLIENT="$CLIENT" TITLE="$TITLE" ORIGINS="$ORIGINS" BITRIX_WEBHOOK="$BITRIX_WEBHOOK" CONF="$CONF" "$NODE_BIN" -e '
    const fs=require("fs"),c=JSON.parse(fs.readFileSync(process.env.CONF,"utf8"));
    c[process.env.CLIENT]=Object.assign(c[process.env.CLIENT]||{},{webhook:process.env.BITRIX_WEBHOOK,title:process.env.TITLE,origins:process.env.ORIGINS.split(/\s+/).filter(Boolean)});
    fs.writeFileSync(process.env.CONF,JSON.stringify(c,null,2));'
  echo "  ✓ вебхук клиента «$CLIENT» сохранён (только на сервере)"
else
  echo "  BITRIX_WEBHOOK не задан — оставляю текущие настройки"
fi
chown root:huma-leads "$CONF"; chmod 640 "$CONF"
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

say "nginx → $SITE_DOMAIN"
cat > /etc/nginx/conf.d/huma-leads-zone.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=huma_leads:1m rate=30r/m;
EOF
cat > /etc/nginx/sites-available/$SITE_DOMAIN.conf <<EOF
server {
  listen 80;
  server_name $SITE_DOMAIN www.$SITE_DOMAIN;
  root $WEB;
  index index.html;
  charset utf-8;

  gzip on; gzip_vary on; gzip_min_length 1024;
  gzip_types text/css application/javascript application/json image/svg+xml;

  # служебное из репозитория наружу не отдаём
  location ~ /\.            { deny all; return 404; }
  location ^~ /server/      { deny all; return 404; }
  location ~ \.(md|xlsx|sh)$ { deny all; return 404; }

  # приёмник заявок
  location /api/lead/ {
    limit_req zone=huma_leads burst=10 nodelay;
    client_max_body_size 32k;
    proxy_pass http://127.0.0.1:$PORT/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_read_timeout 30s;
  }

  # статика: шрифты и картинки кэшируются надолго, страница — без кэша
  location ~* \.(woff2|webp|png|jpg|svg|ico)$ { expires 30d; add_header Cache-Control "public"; try_files \$uri =404; }
  location = /index.html { add_header Cache-Control "no-cache"; }
  location / { try_files \$uri \$uri/ =404; }
}
EOF
ln -sf /etc/nginx/sites-available/$SITE_DOMAIN.conf /etc/nginx/sites-enabled/$SITE_DOMAIN.conf
nginx -t && systemctl reload nginx

say "HTTPS-сертификат Let's Encrypt"
CONFF=/etc/nginx/sites-available/$SITE_DOMAIN.conf
# убрать редирект www, если он остался от прошлой неудачной попытки (мешает проверке сертификата)
sed -i "/if (\$host = www.$SITE_DOMAIN) { return 301 https:\/\/$SITE_DOMAIN\$request_uri; }/d" "$CONFF"
nginx -t -q && systemctl reload nginx
# подождать, если certbot уже чем-то занят (например, плановым продлением)
for i in $(seq 1 30); do pgrep -x certbot >/dev/null || break; [ $i = 1 ] && echo "  certbot сейчас занят другой задачей — жду…"; sleep 5; done
CERT_OK=0
certbot --nginx -n --agree-tos -m "$EMAIL" -d "$SITE_DOMAIN" -d "www.$SITE_DOMAIN" --redirect && CERT_OK=1 \
  || echo "  ⚠ certbot не смог выпустить сертификат — пришлите вывод выше"
# www → без www (только когда HTTPS уже есть)
if [ $CERT_OK = 1 ] && ! grep -q "return 301 https://$SITE_DOMAIN" "$CONFF"; then
  sed -i "0,/server_name $SITE_DOMAIN www.$SITE_DOMAIN;/s//server_name $SITE_DOMAIN www.$SITE_DOMAIN;\n  if (\$host = www.$SITE_DOMAIN) { return 301 https:\/\/$SITE_DOMAIN\$request_uri; }/" "$CONFF"
  nginx -t -q && systemctl reload nginx
fi

say "Проверка"
sleep 1
code_site=$(curl -s -o /dev/null -w '%{http_code}' "https://$SITE_DOMAIN/" || true)
code_api=$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS -H "Origin: https://$SITE_DOMAIN" "https://$SITE_DOMAIN/api/lead/$CLIENT" || true)
echo "  сайт https://$SITE_DOMAIN → $code_site   ·   приёмник заявок → $code_api"
[ "$code_site" = 200 ] && [ "$code_api" = 204 ] && echo "  ✓ Всё работает: сайт открыт, заявки принимаются" \
  || { echo "  ⚠ Что-то не так — пришлите этот вывод"; systemctl status huma-leads --no-pager | tail -8; }
echo
echo "Журнал заявок: $DATA/$CLIENT.jsonl   ·   Логи: journalctl -u huma-leads -f"
