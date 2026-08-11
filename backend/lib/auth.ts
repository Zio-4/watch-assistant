import { createHash, timingSafeEqual } from 'node:crypto';

function digest(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest();
}

export function readBearerCredential(request: Request): string | null {
  const authorization = request.headers.get('authorization');
  if (!authorization) return null;

  const match = /^Bearer\s+(.+)$/i.exec(authorization.trim());
  return match?.[1] ?? null;
}

export function credentialsMatch(
  supplied: string | null,
  expected: string | undefined,
): boolean {
  if (!supplied || !expected) return false;
  return timingSafeEqual(digest(supplied), digest(expected));
}

