import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import { DnsStack } from './dns-stack.js';
import { LandingStack } from './landing-stack.js';
import { ShareStack } from './export-link/share-stack.js';
import { MailStack } from './mail/mail-stack.js';
import type { EnvConfig } from './env-config.js';

export interface AppStageProps extends cdk.StageProps {
  config: EnvConfig;
}

// DnsStack -> LandingStack, MailStack and ShareStack: each takes the hosted
// zone from DnsStack and has no dependency on the others. Every stackName is
// prefixed `ThoughtReps-<env>-` because the AWS account is shared with
// other apps' stacks.
export class AppStage extends cdk.Stage {
  public readonly dns: DnsStack;
  public readonly landing: LandingStack;
  public readonly mail: MailStack;
  public readonly share: ShareStack;

  constructor(scope: Construct, id: string, props: AppStageProps) {
    const {
      envName,
      account,
      region,
      domainName,
      mailboxAddresses,
      alertEmail,
      forwardTo,
      sharedReceiptRuleSetName,
      exportLinkSubdomain,
      appAttestAppId,
      feedbackFromAddress,
      feedbackToAddress,
      waitlistFromAddress,
    } = props.config;
    const env = { account, region };
    super(scope, id, { ...props, env });

    const tags = { Environment: envName };
    const stackId = (name: string) => `ThoughtReps-${envName}-${name}`;

    this.dns = new DnsStack(this, 'DnsStack', {
      env,
      domainName,
      stackName: stackId('Dns'),
      tags,
    });

    this.landing = new LandingStack(this, 'LandingStack', {
      env,
      zone: this.dns.zone,
      domainName,
      exportLinkSubdomain,
      stackName: stackId('Landing'),
      tags,
    });

    this.mail = new MailStack(this, 'MailStack', {
      env,
      zone: this.dns.zone,
      domainName,
      mailboxAddresses,
      alertEmail,
      envName,
      forwardTo,
      sharedReceiptRuleSetName,
      stackName: stackId('Mail'),
      tags,
    });

    this.share = new ShareStack(this, 'ShareStack', {
      env,
      zone: this.dns.zone,
      domainName,
      exportLinkSubdomain,
      appAttestAppId,
      feedbackFromAddress,
      feedbackToAddress,
      waitlistFromAddress,
      stackName: stackId('Share'),
      tags,
    });
  }
}
