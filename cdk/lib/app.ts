import * as cdk from 'aws-cdk-lib';
import { InfraStack } from './infra-stack';
import { Ec2Stack } from './ec2-stack';
import { EcsStack } from './ecs-stack';
import { BatchStack } from './batch-stack';

/**
 * Default: 2 stacks (Infra + EC2) — LocalExecutor, simple setup.
 * With -c executor=ecs: 4 stacks (+ ECS + Batch) — multi-team executor testing.
 *
 * Deploy:  npx cdk deploy --all
 * ECS:    npx cdk deploy --all -c executor=ecs
 * Destroy: npx cdk destroy --all --force
 */

const app = new cdk.App();

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION,
};

const executor = app.node.tryGetContext('executor');

const infra = new InfraStack(app, 'AirflowInfra', {
  terminationProtection: false,
  env,
});

new Ec2Stack(app, 'AirflowEc2', {
  terminationProtection: false,
  env,
  infra: infra.outputs,
});

if (executor === 'ecs') {
  new EcsStack(app, 'AirflowEcs', {
    terminationProtection: false,
    env,
    infra: infra.outputs,
  });

  new BatchStack(app, 'AirflowBatch', {
    terminationProtection: false,
    env,
    infra: infra.outputs,
  });
}
