import { describe, expect, it, vi } from 'vitest';
import { FixedWindowRateLimiter } from '../lib/rate-limit.js';
import { createSessionHandler } from '../lib/session-handler.js';

const configuredEnvironment = {
  WATCH_APP_CREDENTIAL: 'watch-secret',
  AI_GATEWAY_API_KEY: 'gateway-secret',
  REALTIME_MODEL: 'openai/gpt-realtime-mini',
};

function request(credential = 'watch-secret', ip = '192.0.2.10') {
  return new Request('https://service.test/api/realtime/session', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${credential}`,
      'x-forwarded-for': ip,
    },
  });
}

function renewalRequest(appSessionId: string, ip = '192.0.2.10') {
  return new Request('https://service.test/api/realtime/session', {
    method: 'POST',
    headers: {
      authorization: 'Bearer watch-secret',
      'content-type': 'application/json',
      'x-forwarded-for': ip,
    },
    body: JSON.stringify({ appSessionId }),
  });
}

describe('POST /api/realtime/session', () => {
  it('returns a health check on GET', async () => {
    const handler = createSessionHandler({
      env: configuredEnvironment,
      getToken: vi.fn(),
    });

    const response = await handler(
      new Request('https://service.test/api/realtime/session', { method: 'GET' }),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      ok: true,
      service: 'watch-assistant-session',
    });
  });

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
    const body = await response.json();
    expect(body).toMatchObject({
      model: 'openai/gpt-realtime-mini',
      token: 'vcst_test',
      expiresAt: '2027-01-15T08:00:00.000Z',
      audio: { inputFormat: 'audio/pcm', sampleRate: 24_000, channels: 1 },
    });
    expect(body.appSessionId).toMatch(/^session-id\.[A-Za-z0-9_-]+$/);
    expect(getToken).toHaveBeenCalledWith('openai/gpt-realtime-mini', 60);
  });

  it('reuses the application session id when renewing a token', async () => {
    const getToken = vi.fn().mockResolvedValue({
      token: 'vcst_next',
      url: 'wss://ai-gateway.vercel.sh/v1/realtime-model?ai-model-id=test',
      expiresAt: 1_800_000_060,
    });
    const handler = createSessionHandler({
      env: configuredEnvironment,
      getToken,
      limiter: new FixedWindowRateLimiter(1, 60_000),
      randomUUID: () => 'new-session-id',
    });

    const created = await handler(request('watch-secret', '192.0.2.20'));
    const createdBody = await created.json();
    const limited = await handler(request('watch-secret', '192.0.2.20'));
    const renewed = await handler(renewalRequest(createdBody.appSessionId, '192.0.2.20'));

    expect(created.status).toBe(200);
    expect(limited.status).toBe(429);
    expect(renewed.status).toBe(200);
    await expect(renewed.json()).resolves.toMatchObject({
      appSessionId: createdBody.appSessionId,
      token: 'vcst_next',
    });
    expect(getToken).toHaveBeenCalledTimes(2);
  });

  it('rejects a renewal id this server did not issue', async () => {
    const getToken = vi.fn().mockResolvedValue({ token: 'vcst_test', url: 'wss://test' });
    const handler = createSessionHandler({
      env: configuredEnvironment,
      getToken,
      limiter: new FixedWindowRateLimiter(5, 60_000),
      randomUUID: () => 'session-id',
    });

    const malformed = await handler(renewalRequest('not-a-session', '192.0.2.11'));
    const unknown = await handler(
      renewalRequest('11111111-2222-4333-8444-555555555555', '192.0.2.11'),
    );

    expect(malformed.status).toBe(400);
    await expect(malformed.json()).resolves.toEqual({ error: 'invalid_session' });
    expect(unknown.status).toBe(400);
    await expect(unknown.json()).resolves.toEqual({ error: 'invalid_session' });
    expect(getToken).not.toHaveBeenCalled();
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

