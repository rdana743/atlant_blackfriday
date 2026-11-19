/**
 * Cloudflare Worker — зеркало Telegram Bot API для сервера заявок.
 * Нужен потому, что с российских VPS api.telegram.org работает с перебоями.
 *
 * Сервер шлёт запрос на https://<worker>.workers.dev/bot<TOKEN>/sendMessage,
 * Worker пересылает его в api.telegram.org и возвращает ответ.
 *
 * Пропускает ТОЛЬКО ботов из списка BOT_IDS (число из начала токена, до двоеточия),
 * чтобы зеркалом не мог воспользоваться кто-то посторонний.
 * Токен в Worker не хранится — он приходит в самом запросе от вашего сервера.
 */
const BOT_IDS = ['ЗАМЕНИТЕ_НА_ID_БОТА']; // например ['9260916937'] — можно несколько через запятую

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const m = url.pathname.match(/^\/(?:file\/)?bot(\d+):/);
    if (!m || !BOT_IDS.includes(m[1])) return new Response('Not found', { status: 404 });
    url.protocol = 'https:';
    url.hostname = 'api.telegram.org';
    url.port = '';
    return fetch(new Request(url, request));
  },
};
