import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import { createNetwork } from './network';
import { createStorage } from './storage';
import { createIam } from './iam';
import { createNlb } from './loadbalancers';

/** Resources exposed to the compute stacks */
export interface InfraOutputs {
  vpc: ec2.Vpc;
  ec2Sg: ec2.SecurityGroup;
  workerSg: ec2.SecurityGroup;
  ec2Role: iam.Role;
  ecrRepoUri: string;
  taskRoleArn: string;
  ecsExecRoleArn: string;
  nlbArn?: string;
  nlbDns?: string;
}

export interface InfraStackProps extends cdk.StackProps {
  suffix?: string;
}

export class InfraStack extends cdk.Stack {
  public readonly outputs: InfraOutputs;

  constructor(scope: Construct, id: string, props?: InfraStackProps) {
    super(scope, id, props);

    const suffix = props?.suffix || '';
    const ssmPrefix = suffix ? `/airflow-test-${suffix}` : '/airflow-test';

    // 1. Network
    const { vpc, ec2Sg, dbSg, nlbSg, workerSg } = createNetwork(this);

    // 2. Storage
    const { db, dbSecret, logBucket, dagBucket, ecrRepo } = createStorage(this, vpc, dbSg, suffix);

    // 3. IAM
    const { ec2Role, ecsExecRole, taskRole } = createIam(this, logBucket, dagBucket, dbSecret, ecrRepo, ssmPrefix);

    // 4. NLB — only needed for ECS/Batch executor (workers call back to Execution API)
    const executor = this.node.tryGetContext('executor');
    const nlb = executor === 'ecs' ? createNlb(this, vpc, nlbSg) : undefined;

    // 5. SSM params for infra resources (stable across compute stack updates)
    const region = cdk.Stack.of(this).region;
    const privateSubnets = vpc.privateSubnets.map((s) => s.subnetId).join(',');

    const p = (lid: string, name: string, value: string) =>
      new ssm.StringParameter(this, lid, { parameterName: name, stringValue: value });

    p('SsmDbEndpoint', `${ssmPrefix}/db-endpoint`, db.dbInstanceEndpointAddress);
    p('SsmDbPort', `${ssmPrefix}/db-port`, '5432');
    p('SsmDbSecretArn', `${ssmPrefix}/db-secret-arn`, dbSecret.secretArn);
    p('SsmDbName', `${ssmPrefix}/db-name`, 'airflow_db');
    p('SsmEcrRepo', `${ssmPrefix}/ecr-repo`, ecrRepo.repositoryUri);
    p('SsmWorkerSg', `${ssmPrefix}/worker-sg`, workerSg.securityGroupId);
    p('SsmPrivateSubnets', `${ssmPrefix}/private-subnets`, privateSubnets);
    p('SsmLogBucket', `${ssmPrefix}/log-bucket`, logBucket.bucketName);
    p('SsmDagBucket', `${ssmPrefix}/dag-bucket`, dagBucket.bucketName);
    p('SsmRegion', `${ssmPrefix}/region`, region);
    if (nlb) {
      p('SsmNlbDns', `${ssmPrefix}/nlb-dns`, nlb.loadBalancerDnsName);
      new cdk.CfnOutput(this, 'NlbDns', { value: nlb.loadBalancerDnsName });
    }

    this.outputs = {
      vpc, ec2Sg, workerSg, ec2Role,
      ecrRepoUri: ecrRepo.repositoryUri,
      taskRoleArn: taskRole.roleArn,
      ecsExecRoleArn: ecsExecRole.roleArn,
      nlbArn: nlb?.loadBalancerArn,
      nlbDns: nlb?.loadBalancerDnsName,
    };
  }
}
