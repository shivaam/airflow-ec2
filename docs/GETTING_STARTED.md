# Getting Started — Zero to Airflow on EC2

End-to-end guide for deploying Airflow 3.x on a fresh AWS account.

## Prerequisites

On your Mac:
- **AWS CLI v2**: `brew install awscli`
- **Node.js 18+**: `brew install node`
- **SSM plugin**: `brew install --cask session-manager-plugin`

## 1. AWS Account Setup

1. Create a new AWS account (or use an existing one)
2. Create an IAM user with `AdministratorAccess` policy
3. Create an access key for that user:
   - IAM Console → Users → your user → Security credentials → Create access key
   - Select "Command Line Interface (CLI)" as the use case
4. Configure your local CLI:

```bash
aws configure
# Access Key ID: <your-key>
# Secret Access Key: <your-secret>
# Default region: us-west-2  (or your preferred region)
# Output format: json
```

5. Verify:
```bash
aws sts get-caller-identity
# Should return your account ID and IAM user ARN
```

> **Security note**: Never share your Secret Access Key. For long-term use,
> consider switching to IAM Identity Center (SSO) for temporary credentials.

## 2. Bootstrap CDK

CDK needs a one-time bootstrap per account/region:

```bash
cd cdk
npx cdk bootstrap aws://<ACCOUNT_ID>/<REGION>
```

## 3. Deploy

Default deploy creates 2 stacks (Infra + EC2) with LocalExecutor:

```bash
make deploy
# or: cd cdk && npx cdk deploy --all --require-approval never
```

This takes ~8 minutes. Creates: VPC, NAT Gateway, RDS, S3 buckets, EC2 instance.

For ECS/Batch executor testing (adds NLB + ECS + Batch stacks):
```bash
make deploy-ecs
```

## 4. Set Up Airflow on EC2

After CDK deploy, the EC2 instance has base tools (Docker, Python, git) but
Airflow is not yet installed. Get the instance ID from the deploy output, then:

```bash
# SSM into the instance
aws ssm start-session --target <instance-id>
sudo su - ec2-user

# Run the one-shot setup (~10 min: clone, install, build UI, init DB, start)
bash /opt/airflow-scripts/setup-airflow.sh
```

You can also run this remotely without an interactive session:

```bash
aws ssm send-command \
  --instance-ids <instance-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo npm install -g pnpm && sudo -u ec2-user bash /opt/airflow-scripts/setup-airflow.sh 2>&1"]' \
  --timeout-seconds 1800
```

Check status:
```bash
aws ssm get-command-invocation \
  --command-id <command-id> \
  --instance-id <instance-id> \
  --query 'Status' --output text
```

## 5. Access the Airflow UI

Create an SSM tunnel from your Mac:

```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

Then open http://localhost:8080

## 6. Tear Down

```bash
make destroy
# or: cd cdk && npx cdk destroy --all --force
```

Everything is destroyed — VPC, RDS, EC2, S3 buckets. No lingering costs.

## Cost Breakdown

Default deploy (LocalExecutor, no NLB):

| Resource | Monthly Cost |
|----------|-------------|
| NAT Gateway (1x) | ~$32 |
| RDS t3.small | ~$25 |
| EC2 t3.large | ~$60 |
| EBS 50GB gp3 | ~$4 |
| S3 (minimal) | ~$1 |
| **Total** | **~$122/mo (~$4/day)** |

Stop the EC2 instance when not in use to save on compute.
Destroy the whole stack when done to pay nothing.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `SessionManagerPlugin is not found` | `brew install --cask session-manager-plugin` |
| pnpm install fails with EACCES | Fixed in setup script — uses `sudo npm install -g pnpm` |
| CDK bootstrap fails | Check `aws sts get-caller-identity` returns correct account |
| Setup script hangs | The git clone + UI build takes ~10 min — be patient |
| Port 8080 not responding after setup | Wait 30s for API server startup, then check `af status` on EC2 |
