import { Logger } from '@nestjs/common';
import type { BatchResponse, MulticastMessage } from 'firebase-admin/messaging';

/**
 * Push is a best-effort delivery layer on top of stored notifications (§7.8).
 * Nothing depends on it succeeding: a notification that fails to push is
 * still waiting in the app's notification centre.
 */
export interface PushMessage {
  title: string;
  body: string;
  /** FCM data values must be strings. */
  data: Record<string, string>;
}

export interface PushSender {
  /** Resolves with the tokens FCM reported dead, so the caller can forget them. */
  send(tokens: string[], message: PushMessage): Promise<{ invalidTokens: string[] }>;
}

export const PUSH_SENDER = Symbol('PUSH_SENDER');

/** The sender when no Firebase project is configured: every notification is still stored. */
export class NoopPushSender implements PushSender {
  async send(): Promise<{ invalidTokens: string[] }> {
    return { invalidTokens: [] };
  }
}

/** The part of firebase-admin's Messaging this sender uses, so tests can stand in for it. */
export interface MulticastMessaging {
  sendEachForMulticast(message: MulticastMessage): Promise<BatchResponse>;
}

/** FCM's own limit on tokens per multicast. */
const MAX_TOKENS_PER_MULTICAST = 500;

/** Errors that mean the token will never work again, not that FCM had a bad moment. */
const DEAD_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
]);

export class FcmPushSender implements PushSender {
  constructor(private readonly messaging: MulticastMessaging) {}

  async send(tokens: string[], message: PushMessage): Promise<{ invalidTokens: string[] }> {
    const invalidTokens: string[] = [];
    for (let start = 0; start < tokens.length; start += MAX_TOKENS_PER_MULTICAST) {
      const chunk = tokens.slice(start, start + MAX_TOKENS_PER_MULTICAST);
      const result = await this.messaging.sendEachForMulticast({
        tokens: chunk,
        notification: { title: message.title, body: message.body },
        data: message.data,
      });
      result.responses.forEach((response, i) => {
        if (!response.success && DEAD_TOKEN_CODES.has(response.error?.code ?? '')) {
          invalidTokens.push(chunk[i]);
        }
      });
    }
    return { invalidTokens };
  }
}

/**
 * FCM when a service account is configured, otherwise no push at all.
 * firebase-admin is imported only then, so a server without Firebase never
 * loads it.
 */
export async function createPushSender(serviceAccountJson: string | undefined): Promise<PushSender> {
  if (!serviceAccountJson) {
    new Logger('PushSender').log('FIREBASE_SERVICE_ACCOUNT_JSON is not set: push is off');
    return new NoopPushSender();
  }
  const { cert, getApps, initializeApp } = await import('firebase-admin/app');
  const { getMessaging } = await import('firebase-admin/messaging');
  const app =
    getApps().find((a) => a.name === 'medinv') ??
    initializeApp({ credential: cert(JSON.parse(serviceAccountJson)) }, 'medinv');
  return new FcmPushSender(getMessaging(app));
}
