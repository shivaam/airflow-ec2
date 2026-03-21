import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { InfraOutputs } from './infra-stack';
import { createEc2 } from './compute';
import { registerNlbTarget } from './loadbalancers';

export interface Ec2StackProps extends cdk.StackProps {
  infra: InfraOutputs;
  suffix?: string;
}

export class Ec2Stack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: Ec2StackProps) {
    super(scope, id, props);

    const { vpc, ec2Sg, ec2Role, nlbArn } = props.infra;
    const suffix = props.suffix || '';
    const ssmPrefix = suffix ? `/airflow-test-${suffix}` : '/airflow-test';

    // 1. EC2 instance
    const instance = createEc2(this, vpc, ec2Sg, ec2Role, ssmPrefix);

    // 2. Register EC2 as NLB target (only when NLB exists — ECS executor mode)
    if (nlbArn) {
      registerNlbTarget(this, vpc, nlbArn, instance);
    }

    // Output for SSM tunnel
    new cdk.CfnOutput(this, 'Ec2InstanceId', {
      value: instance.instanceId,
      description: 'SSM tunnel: aws ssm start-session --target <id> --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=8080',
    });
  }
}
