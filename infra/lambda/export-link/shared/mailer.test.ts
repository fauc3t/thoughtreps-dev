import type { SESv2Client } from '@aws-sdk/client-sesv2';
import { SesMailer } from './mailer.js';

describe('SesMailer', () => {
  it('sends a Simple-content SendEmail with Reply-To and UTF-8 text', async () => {
    const send = jest.fn().mockResolvedValue({});
    const mailer = new SesMailer({ send } as unknown as SESv2Client);

    await mailer.send({
      from: 'feedback@example.test',
      to: 'hello@example.test',
      replyTo: 'person@example.com',
      subject: '[Bug] Feedback',
      text: 'body',
    });

    expect(send).toHaveBeenCalledTimes(1);
    const [command] = send.mock.calls[0] as [{ input: unknown }];
    expect(command.input).toEqual({
      FromEmailAddress: 'feedback@example.test',
      Destination: { ToAddresses: ['hello@example.test'] },
      ReplyToAddresses: ['person@example.com'],
      Content: {
        Simple: {
          Subject: { Data: '[Bug] Feedback', Charset: 'UTF-8' },
          Body: { Text: { Data: 'body', Charset: 'UTF-8' } },
        },
      },
    });
  });

  it('omits ReplyToAddresses when there is no replyTo', async () => {
    const send = jest.fn().mockResolvedValue({});
    await new SesMailer({ send } as unknown as SESv2Client).send({
      from: 'waitlist@example.test',
      to: 'hello@example.test',
      subject: 's',
      text: 'body',
    });
    const [command] = send.mock.calls[0] as [{ input: object }];
    expect(command.input).not.toHaveProperty('ReplyToAddresses');
  });
});
