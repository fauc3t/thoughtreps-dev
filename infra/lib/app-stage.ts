import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import { DnsStack } from './dns-stack.js';
import { LandingStack } from './landing-stack.js';
import { MailStack } from './mail/mail-stack.js';
import type { EnvConfig } from './env-config.js';

export interface AppStageProps extends cdk.StageProps {
  config: EnvConfig;
}

// DnsStack -> LandingStack and MailStack: both take the hosted zone from
// DnsStack and have no dependency on each other. Every stackName is
// prefixed `ThoughtReps-<env>-` because the AWS account is shared with
// other apps' stacks.
export class AppStage extends cdk.Stage {
  public readonly dns: DnsStack;
  public readonly landing: LandingStack;
  public readonly mail: MailStack;

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
  }
}
