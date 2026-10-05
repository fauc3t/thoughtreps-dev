import * as cdk from 'aws-cdk-lib/core';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { Construct } from 'constructs';

export interface DnsStackProps extends cdk.StackProps {
  domainName: string;
}

// Split out from the other stacks deliberately: the registrar's nameserver
// records point at this zone by ID. Deleting/recreating it would change that
// ID and silently break DNS until someone re-points the registrar. RETAIN
// means `cdk destroy` on this stack won't delete the zone either.
export class DnsStack extends cdk.Stack {
  public readonly zone: route53.HostedZone;

  constructor(scope: Construct, id: string, props: DnsStackProps) {
    super(scope, id, props);

    const { domainName } = props;

    this.zone = new route53.HostedZone(this, 'Zone', { zoneName: domainName });
    this.zone.applyRemovalPolicy(cdk.RemovalPolicy.RETAIN);

    new cdk.CfnOutput(this, 'NameServers', {
      value: cdk.Fn.join(', ', this.zone.hostedZoneNameServers ?? []),
      description: `Set these as the custom nameservers for ${domainName} at the registrar`,
    });
  }
}
