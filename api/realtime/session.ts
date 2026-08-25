import { createSessionHandler } from '../../backend/lib/session-handler.js';

export const runtime = 'nodejs';

const handler = createSessionHandler();

export function GET(): Response {
  return Response.json(
    {
      ok: true,
      service: 'watch-assistant-session',
      hint: 'POST with Authorization: Bearer <WATCH_APP_CREDENTIAL>',
    },
    { headers: { 'cache-control': 'no-store' } },
  );
}

export function POST(request: Request): Promise<Response> {
  return handler(request);
}

export default {
  fetch: handler,
};
