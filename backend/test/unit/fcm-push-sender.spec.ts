import type { BatchResponse, MulticastMessage } from 'firebase-admin/messaging';
import { describe, expect, it } from 'vitest';

import { FcmPushSender } from '../../src/notifications/push-sender';

type Outcome = { success: true } | { success: false; code: string };

/** A stand-in for firebase-admin's Messaging that records what it was asked to send. */
function fakeMessaging(outcome: (token: string) => Outcome = () => ({ success: true })) {
  const calls: MulticastMessage[] = [];
  const messaging = {
    async sendEachForMulticast(message: MulticastMessage): Promise<BatchResponse> {
      calls.push(message);
      const responses = message.tokens.map((token) => {
        const o = outcome(token);
        return o.success
          ? { success: true, messageId: `m-${token}` }
          : { success: false, error: { code: o.code, message: o.code } };
      }) as BatchResponse['responses'];
      return {
        responses,
        successCount: responses.filter((r) => r.success).length,
        failureCount: responses.filter((r) => !r.success).length,
      };
    },
  };
  return { calls, messaging };
}

const message = { title: 'نفد شاش', body: 'اطلب الآن من التطبيق.', data: { itemId: 'i1' } };

describe('FcmPushSender', () => {
  it('sends at most 500 tokens per multicast, FCM’s own limit', async () => {
    const { calls, messaging } = fakeMessaging();
    const tokens = Array.from({ length: 1200 }, (_, i) => `t${i}`);

    await new FcmPushSender(messaging).send(tokens, message);

    expect(calls.map((c) => c.tokens.length)).toEqual([500, 500, 200]);
  });

  it('puts the title and body in the notification and passes the data through', async () => {
    const { calls, messaging } = fakeMessaging();

    await new FcmPushSender(messaging).send(['t1'], message);

    expect(calls[0]).toMatchObject({
      tokens: ['t1'],
      notification: { title: 'نفد شاش', body: 'اطلب الآن من التطبيق.' },
      data: { itemId: 'i1' },
    });
  });

  it('asks Android for high priority, so a sleeping phone shows it at once', async () => {
    const { calls, messaging } = fakeMessaging();

    await new FcmPushSender(messaging).send(['t1'], message);

    expect(calls[0].android).toEqual({ priority: 'high' });
  });

  it('reports only the tokens FCM says are dead', async () => {
    const { messaging } = fakeMessaging((token) =>
      token === 't2'
        ? { success: false, code: 'messaging/registration-token-not-registered' }
        : token === 't3'
          ? { success: false, code: 'messaging/invalid-registration-token' }
          : token === 't4'
            ? { success: false, code: 'messaging/internal-error' } // transient: keep it
            : { success: true },
    );

    const result = await new FcmPushSender(messaging).send(['t1', 't2', 't3', 't4'], message);

    expect(result).toEqual({ invalidTokens: ['t2', 't3'] });
  });

  it('sends nothing for no tokens', async () => {
    const { calls, messaging } = fakeMessaging();

    expect(await new FcmPushSender(messaging).send([], message)).toEqual({ invalidTokens: [] });
    expect(calls).toEqual([]);
  });
});
