import { credentialsMatch, readBearerCredential } from './auth.js';
import { createGatewayToken, type GatewayToken } from './gateway.js';
import { FixedWindowRateLimiter, requestClientKey } from './rate-limit.js';

type Environment = {
  WATCH_APP_CREDENTIAL?: string;
  AI_GATEWAY_API_KEY?: string;
  VERCEL_OIDC_TOKEN?: string;
  REALTIME_MODEL?: string;
};

type Dependencies = {
  env?: Environment;
  getToken?: (model: string, expiresAfterSeconds: number) => Promise<GatewayToken>;
  limiter?: FixedWindowRateLimiter;
  randomUUID?: () => string;
};

const defaultLimiter = new FixedWindowRateLimiter(5, 60_000);

function json(body: unknown, status: number, headers?: HeadersInit): Response {
  return Response.json(body, {
    status,
    headers: {
      'cache-control': 'no-store',
      ...headers,
    },
  });
}

export function createSessionHandler(dependencies: Dependencies = {}) {
  const env = dependencies.env ?? process.env;
  const getToken = dependencies.getToken ?? createGatewayToken;
  const limiter = dependencies.limiter ?? defaultLimiter;
  const randomUUID = dependencies.randomUUID ?? (() => crypto.randomUUID());

  return async function handleSession(request: Request): Promise<Response> {
    if (request.method !== 'POST') {
      return json({ error: 'method_not_allowed' }, 405, { allow: 'POST' });
    }

    if (!env.WATCH_APP_CREDENTIAL) {
      console.error('WATCH_APP_CREDENTIAL is not configured');
      return json({ error: 'server_not_configured' }, 500);
    }

    if (!env.AI_GATEWAY_API_KEY && !env.VERCEL_OIDC_TOKEN) {
      console.error('AI Gateway authentication is not configured');
      return json({ error: 'server_not_configured' }, 500);
    }

    if (!credentialsMatch(readBearerCredential(request), env.WATCH_APP_CREDENTIAL)) {
      return json({ error: 'unauthorized' }, 401, {
        'www-authenticate': 'Bearer',
      });
    }

    const rateLimit = limiter.consume(requestClientKey(request));
    if (!rateLimit.allowed) {
      return json({ error: 'rate_limited' }, 429, {
        'retry-after': String(rateLimit.retryAfter),
      });
    }

    const model = env.REALTIME_MODEL ?? 'openai/gpt-realtime-mini';
    const appSessionId = randomUUID();

    try {
      const session = await getToken(model, 60);
      const expiresAt = session.expiresAt
        ? new Date(session.expiresAt * 1000).toISOString()
        : new Date(Date.now() + 60_000).toISOString();

      return json(
        {
          appSessionId,
          model,
          url: session.url,
          token: session.token,
          expiresAt,
          audio: {
            inputFormat: 'audio/pcm',
            outputFormat: 'audio/pcm',
            sampleRate: 24_000,
            channels: 1,
          },
        },
        200,
      );
    } catch (error) {
      console.error('Failed to create AI Gateway session', {
        appSessionId,
        message: error instanceof Error ? error.message : 'Unknown error',
      });
      return json({ error: 'session_creation_failed', appSessionId }, 502);
    }
  };
}
