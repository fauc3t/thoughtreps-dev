import { SendEmailCommand, type SESv2Client } from '@aws-sdk/client-sesv2';

export interface OutgoingMail {
  from: string;
  to: string;
  replyTo?: string;
  subject: string;
  text: string;
}

export interface Mailer {
  send(mail: OutgoingMail): Promise<void>;
}

export class SesMailer implements Mailer {
  constructor(private readonly ses: SESv2Client) {}

  async send(mail: OutgoingMail) {
    await this.ses.send(
      new SendEmailCommand({
        FromEmailAddress: mail.from,
        Destination: { ToAddresses: [mail.to] },
        ...(mail.replyTo && { ReplyToAddresses: [mail.replyTo] }),
        Content: {
          Simple: {
            Subject: { Data: mail.subject, Charset: 'UTF-8' },
            Body: { Text: { Data: mail.text, Charset: 'UTF-8' } },
          },
        },
      }),
    );
  }
}
