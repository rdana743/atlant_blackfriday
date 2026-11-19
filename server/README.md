# huma-leads — заявки с лендинга в Битрикс24

Небольшой сервис на Node.js (без зависимостей): принимает заявки с лендинга и создаёт лиды в Битрикс24 через входящий вебхук клиента.

- **Вебхук хранится только на сервере** (`/etc/huma-leads/clients.json`), в коде лендинга и в репозитории его нет.
- Принимает заявки только с разрешённых сайтов (CORS), отсеивает ботов (скрытое поле) и флуд (лимит на IP).
- Каждая заявка дублируется в журнал `/var/lib/huma-leads/<клиент>.jsonl`. Если Битрикс не ответил, заявка не потеряется.
- В лид попадают: телефон, форма-источник, ответы квиза, скидка, страница, UTM-метки (в стандартные поля UTM), yclid/gclid.

## Установка

1. В DNS домена `huma.marketing` добавить A-запись: `leads` → IP сервера.
2. На сервере под root:

```bash
curl -fsSL https://raw.githubusercontent.com/rdana743/atlant_blackfriday/main/server/setup.sh -o setup.sh
BITRIX_WEBHOOK='https://ВАШ_ПОРТАЛ/rest/ID/КЛЮЧ/' bash setup.sh
```

Скрипт ставит nginx, certbot и Node.js (если их нет), создаёт systemd-сервис, конфиг nginx и HTTPS-сертификат.

3. В `index.html` в `window.LANDING` указать `endpoint: 'https://leads.huma.marketing/atlant'`.

## Новый клиент

```bash
CLIENT=bvshd TITLE='БВШД · курсы' ORIGINS='https://britishdesign.ru' BITRIX_WEBHOOK='https://...' bash setup.sh
```

Адрес для его лендинга: `https://leads.huma.marketing/bvshd`.

## Полезное

```bash
journalctl -u huma-leads -f                 # логи в реальном времени
tail -n 20 /var/lib/huma-leads/atlant.jsonl # последние заявки
systemctl reload huma-leads                 # перечитать clients.json без рестарта
```
