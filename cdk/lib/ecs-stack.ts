import * as cdk from 'aws-cdk-lib';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import { InfraOutputs } from './infra-stack';
import { createEcs } from './ecs';

export interface EcsStackProps extends cdk.StackProps {
  infra: InfraOutputs;
  suffix?: string;
}

export class EcsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: EcsStackProps) {
    super(scope, id, props);

    const { vpc, ecrRepoUri, taskRoleArn, ecsExecRoleArn, nlbDns } = props.infra;
    if (!nlbDns) throw new Error('ECS stack requires NLB — deploy with -c executor=ecs');
    const suffix = props.suffix || '';
    const nameSuffix = suffix ? `-${suffix}` : '';
    const ssmPrefix = suffix ? `/airflow-test-${suffix}` : '/airflow-test';
    const dagBucketName = `airflow-ecs-dags${nameSuffix}-${this.account}-${this.region}`;

    const { alphaCluster, betaCluster, alphaTaskDef, betaTaskDef } = createEcs(
      this, vpc, ecrRepoUri, taskRoleArn, ecsExecRoleArn, nlbDns, dagBucketName,
    );

    // SSM params
    const p = (lid: string, name: string, value: string) =>
      new ssm.StringParameter(this, lid, { parameterName: name, stringValue: value });

    p('SsmAlphaCluster', `${ssmPrefix}/alpha-cluster`, alphaCluster.clusterName);
    p('SsmAlphaTaskDef', `${ssmPrefix}/alpha-task-def`, alphaTaskDef.family);
    p('SsmBetaCluster', `${ssmPrefix}/beta-cluster`, betaCluster.clusterName);
    p('SsmBetaTaskDef', `${ssmPrefix}/beta-task-def`, betaTaskDef.family);
  }
}
