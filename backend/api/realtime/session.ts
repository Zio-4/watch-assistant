import { createSessionHandler } from '../../lib/session-handler.js';

export const runtime = 'nodejs';

const handler = createSessionHandler();

export function POST(request: Request): Promise<Response> {
  return handler(request);
}

export default {
  fetch: handler,
};

