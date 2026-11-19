# Размещение на VPS: лендинг + заявки в Битрикс24

Схема на одном домене (например, `stomat.shop`):

- `https://stomat.shop/` — сам лендинг. Файлы берутся из этого репозитория и **обновляются автоматически**: раз в 2 минуты сервер подтягивает ветку `main` из GitHub.
- `https://stomat.shop/api/lead/atlant` — приёмник заявок (`server.js`). Создаёт лид в Битрикс24 через входящий вебхук клиента.

## Безопасность

- Вебхук хранится **только на сервере** (`/etc/huma-leads/clients.json`). В коде лендинга и в репозитории его нет.
- Заявки принимаются только с разрешённых сайтов, боты отсеиваются скрытым полем, флуд — лимитом на IP (nginx + сервис).
- Папка `server/`, `.git`, `.md`, `.xlsx` наружу не отдаются.
- Каждая заявка дублируется в журнал `/var/lib/huma-leads/<клиент>.jsonl`. Если Битрикс не ответил, заявка не потеряется.

## Что попадает в лид

Название лида: «Атлант · Чёрная пятница 11.11 — <форма>». Телефон — в поле телефона. Ответы квиза, выбранная позиция, скидка, страница и referrer — в комментарий. `utm_*` — в стандартные UTM-поля лида, yclid/gclid — в комментарий.

## Установка

1. DNS домена: две A-записи на IP сервера — `@` и `www`.
2. На сервере под root:

```bash
curl -fsSL https://raw.githubusercontent.com/rdana743/atlant_blackfriday/main/server/setup.sh -o setup.sh
SITE_DOMAIN=stomat.shop BITRIX_WEBHOOK='https://ПОРТАЛ/rest/ID/КЛЮЧ/' bash setup.sh
```

Скрипт ставит nginx, certbot, git и Node.js (если их нет), разворачивает сайт, сервис заявок, HTTPS-сертификат и редирект www → без www. В конце пишет «✓ Всё работает». Повторный запуск безопасен.

## Полезное

```bash
journalctl -u huma-leads -f                  # логи сервиса в реальном времени
tail -n 20 /var/lib/huma-leads/atlant.jsonl  # последние заявки
systemctl reload huma-leads                  # перечитать clients.json без рестарта
```

## Новый клиент на том же сервере

```bash
SITE_DOMAIN=новыйдомен.ru CLIENT=bvshd TITLE='БВШД · курсы' REPO=https://github.com/.../landing.git \
BITRIX_WEBHOOK='https://...' bash setup.sh
```

## Уведомления в Telegram

Каждая заявка дублируется сообщением в группу Telegram: телефон (кликабельный), форма, ответы квиза, UTM, ссылка, статус лида в Битриксе (если лид в CRM не создался, это видно сразу) и хэштеги `#заявка #квиз #yandex` для поиска.

С российских VPS `api.telegram.org` работает с перебоями, поэтому запросы идут через **Cloudflare Worker-зеркало** (`worker/tg-mirror.js`). Токен в Worker не хранится, а сам Worker пропускает только ботов из списка `BOT_IDS`.

1. **Бот и группа.** Создать группу, добавить в неё бота, написать любое сообщение. Открыть `https://api.telegram.org/bot<ТОКЕН>/getUpdates` и взять `"chat":{"id":…}`: это `TG_CHAT_ID` (для групп число с минусом).
2. **Зеркало.** dash.cloudflare.com → Workers & Pages → Create → Worker → Deploy → Edit code → вставить `worker/tg-mirror.js`, в `BOT_IDS` вписать число из начала токена (до двоеточия) → Deploy. Если зеркало уже есть, достаточно добавить ID бота в `BOT_IDS`.
3. **На сервере:**

```bash
TG_TOKEN='123:ABC' TG_CHAT_ID='-100…' TG_API_ROOT='https://ЗЕРКАЛО.workers.dev' SITE_DOMAIN=stomat.shop bash setup.sh
```

Скрипт сохранит настройки на сервере и сразу отправит в группу тестовое сообщение.
