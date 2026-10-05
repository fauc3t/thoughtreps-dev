import * as cdk from 'aws-cdk-lib/core';
import { AppStage } from '../lib/app-stage.js';
import { resolveEnvConfig } from '../lib/env-config.js';

describe('AppStage', () => {
  const app = new cdk.App();
  const config = resolveEnvConfig('prod');
  const stage = new AppStage(app, config.envName, { config });
  const stacks = stage.node
    .findAll()
    .filter((node): node is cdk.Stack => cdk.Stack.isStack(node));

  it('wires exactly the Dns, Landing, Mail and Share stacks', () => {
    expect(stacks.map((stack) => stack.stackName).sort()).toEqual([
      'ThoughtReps-prod-Dns',
      'ThoughtReps-prod-Landing',
      'ThoughtReps-prod-Mail',
      'ThoughtReps-prod-Share',
    ]);
  });

  it('prefixes every stackName with ThoughtReps-prod- (the account is shared with other apps)', () => {
    for (const stack of stacks) {
      expect(stack.stackName.startsWith('ThoughtReps-prod-')).toBe(true);
    }
  });

  it('targets the shared account and region', () => {
    for (const stack of stacks) {
      expect(stack.account).toBe('041459489812');
      expect(stack.region).toBe('us-east-1');
    }
  });
});

describe('resolveEnvConfig', () => {
  it('defaults to prod', () => {
    expect(resolveEnvConfig(undefined).envName).toBe('prod');
  });

  it('throws on any other environment', () => {
    expect(() => resolveEnvConfig('dev')).toThrow();
  });
});
