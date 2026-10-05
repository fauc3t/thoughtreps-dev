import * as cdk from 'aws-cdk-lib/core';
import { Template } from 'aws-cdk-lib/assertions';
import { DnsStack } from '../lib/dns-stack.js';

describe('DnsStack', () => {
  const app = new cdk.App();
  const stack = new DnsStack(app, 'TestDnsStack', {
    env: { account: '111111111111', region: 'us-east-1' },
    domainName: 'example.test',
  });
  const template = Template.fromStack(stack);

  it('creates the hosted zone and retains it on delete/replace', () => {
    template.hasResource('AWS::Route53::HostedZone', {
      Properties: { Name: 'example.test.' },
      DeletionPolicy: 'Retain',
      UpdateReplacePolicy: 'Retain',
    });
  });

  it('outputs the zone nameservers', () => {
    template.hasOutput('NameServers', {});
  });
});
