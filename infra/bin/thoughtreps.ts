#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { AppStage } from '../lib/app-stage.js';
import { resolveEnvConfig } from '../lib/env-config.js';

const app = new cdk.App();
const config = resolveEnvConfig(app.node.tryGetContext('env'));

new AppStage(app, config.envName, { config });
