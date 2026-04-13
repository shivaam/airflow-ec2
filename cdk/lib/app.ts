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
const suffix: string = app.node.tryGetContext('suffix') || '';
const stackSuffix = suffix ? `-${suffix}` : '';
const repo = app.node.tryGetContext('repo') || 'https://github.com/apache/airflow.git';
const branch = app.node.tryGetContext('branch') || 'main';

const infra = new InfraStack(app, `AirflowInfra${stackSuffix}`, {
  terminationProtection: false,
  env,
  suffix,
  airflowRepo: repo,
  airflowBranch: branch,
});

new Ec2Stack(app, `AirflowEc2${stackSuffix}`, {
  terminationProtection: false,
  env,
  infra: infra.outputs,
  suffix,
});

if (executor === 'ecs') {
  new EcsStack(app, `AirflowEcs${stackSuffix}`, {
    terminationProtection: false,
    env,
    infra: infra.outputs,
    suffix,
  });

  new BatchStack(app, `AirflowBatch${stackSuffix}`, {
    terminationProtection: false,
    env,
    infra: infra.outputs,
    suffix,
  });
}
