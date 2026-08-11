import { describe, expect, it } from 'vitest';
import { credentialsMatch, readBearerCredential } from '../lib/auth.js';

describe('credential authentication', () => {
  it('reads a bearer credential', () => {
    const request = new Request('https://example.test', {
      headers: { authorization: 'Bearer watch-secret' },
    });

    expect(readBearerCredential(request)).toBe('watch-secret');
  });

  it('compares credentials without exposing either value', () => {
    expect(credentialsMatch('watch-secret', 'watch-secret')).toBe(true);
    expect(credentialsMatch('wrong', 'watch-secret')).toBe(false);
    expect(credentialsMatch(null, 'watch-secret')).toBe(false);
  });
});

