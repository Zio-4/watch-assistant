import { describe, expect, it, vi } from 'vitest';
import { FixedWindowRateLimiter } from '../lib/rate-limit.js';
import { createSessionHandler } from '../lib/session-handler.js';

const configuredEnvironment = {
  WATCH_APP_CREDENTIAL: 'watch-secret',
  AI_GATEWAY_API_KEY: 'gateway-secret',
  REALTIME_MODEL: 'openai/gpt-realtime-mini',
};

function request(credential = 'watch-secret') {
  return new Request('https://service.test/api/realtime/session', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${credential}`,
      'x-forwarded-for': '192.0.2.10',
    },
  });
}

describe('POST /api/realtime/session', () => {
  it('returns a short-lived session and audio settings', async () => {
    const getToken = vi.fn().mockResolvedValue({
      token: 'vcst_test',
      url: 'wss://ai-gateway.vercel.sh/v1/realtime-model?ai-model-id=test',
      expiresAt: 1_800_000_000,
    });
    const handler = createSessionHandler({
      env: configuredEnvironment,
      getToken,
      limiter: new FixedWindowRateLimiter(5, 60_000),
      randomUUID: () => 'session-id',
    });

    const response = await handler(request());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      appSessionId: 'session-id',
      model: 'openai/gpt-realtime-mini',
      token: 'vcst_test',
      expiresAt: '2027-01-15T08:00:00.000Z',
      audio: { inputFormat: 'audio/pcm', sampleRate: 24_000, channels: 1 },
    });
    expect(getToken).toHaveBeenCalledWith('openai/gpt-realtime-mini', 60);
  });

  it('rejects an invalid personal credential', async () => {
    const handler = createSessionHandler({
      env: configuredEnvironment,
      getToken: vi.fn(),
      limiter: new FixedWindowRateLimiter(5, 60_000),
    });

    const response = await handler(request('wrong'));

    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toEqual({ error: 'unauthorized' });
  });

  it('rate limits repeated session creation', async () => {
    const handler = createSessionHandler({
      env: configuredEnvironment,
      getToken: vi.fn().mockResolvedValue({ token: 'token', url: 'wss://test' }),
      limiter: new FixedWindowRateLimiter(1, 60_000),
    });

    expect((await handler(request())).status).toBe(200);
    const limited = await handler(request());
    expect(limited.status).toBe(429);
    expect(limited.headers.get('retry-after')).toBeTruthy();
  });
});

