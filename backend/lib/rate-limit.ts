type Entry = { startedAt: number; count: number };

export class FixedWindowRateLimiter {
  private readonly entries = new Map<string, Entry>();

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
  ) {}

  consume(key: string, now = Date.now()): { allowed: boolean; retryAfter: number } {
    const existing = this.entries.get(key);
    if (!existing || now - existing.startedAt >= this.windowMs) {
      this.entries.set(key, { startedAt: now, count: 1 });
      return { allowed: true, retryAfter: 0 };
    }

    if (existing.count >= this.limit) {
      const remainingMs = this.windowMs - (now - existing.startedAt);
      return { allowed: false, retryAfter: Math.max(1, Math.ceil(remainingMs / 1000)) };
    }

    existing.count += 1;
    return { allowed: true, retryAfter: 0 };
  }
}

export function requestClientKey(request: Request): string {
  const forwarded = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim();
  return forwarded || request.headers.get('x-real-ip') || 'unknown';
}

