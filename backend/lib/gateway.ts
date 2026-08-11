import { gateway } from '@ai-sdk/gateway';

export type GatewayToken = {
  token: string;
  url: string;
  expiresAt?: number;
};

export async function createGatewayToken(
  model: string,
  expiresAfterSeconds = 60,
): Promise<GatewayToken> {
  return gateway.experimental_realtime.getToken({
    model,
    expiresAfterSeconds,
  });
}

