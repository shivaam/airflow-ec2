# Getting Started — Zero to Airflow on EC2

End-to-end guide for deploying Airflow 3.x on a fresh AWS account.
Tested end-to-end on 2026-03-20 from a brand new AWS account to a successful
ECS executor DAG run in a single session.

## Time Estimates

| Step | Time |
|------|------|
| AWS account + IAM setup | ~5 min |
| CDK bootstrap | ~3 min |
| CDK deploy (LocalExecutor, 2 stacks) | ~8 min |
| CDK deploy (+ ECS/Batch, 4 stacks) | ~5 min (incremental) |
| Airflow setup on EC2 | ~10 min |
| Worker image build (Breeze from source) | ~30 min |
| ECR push (4GB image) | ~5 min |
| **Total (LocalExecutor only)** | **~25 min** |
| **Total (with ECS executor test)** | **~60 min** |

## Prerequisites

On your Mac:
- **AWS CLI v2**: `brew install awscli`
- **Node.js 18+**: `brew install node`
- **SSM plugin**: `brew install --cask session-manager-plugin`

Verify all three:
```bash
aws --version          # v2.x
node --version         # v18+
session-manager-plugin # should print version info
```

## 1. AWS Account Setup (~5 min)

1. Create a new AWS account (or use an existing one)
2. Create an IAM user with `AdministratorAccess` policy
3. Create an access key for that user:
   - IAM Console → Users → your user → **Security credentials** tab
   - Click **Create access key**
   - Select **"Command Line Interface (CLI)"** as the use case
   - AWS will suggest alternatives (SSO, CloudShell) — click past this for now
   - Save the Access Key ID and Secret Access Key
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

> **Security notes**:
> - Never share your Secret Access Key in chat, docs, or code
> - If you accidentally started `aws configure sso` and cancelled, your
>   `~/.aws/config` may be corrupted with SSO prompt text as values.
>   Fix: `rm ~/.aws/config && aws configure --profile default`
> - For long-term use, consider switching to IAM Identity Center (SSO)
>   for temporary credentials — see "IAM Identity Center" section below

## 2. Bootstrap CDK (~3 min)

CDK needs a one-time bootstrap per account/region:

```bash
cd cdk
npx cdk bootstrap aws://<ACCOUNT_ID>/<REGION>
```

This creates an S3 bucket and IAM roles that CDK needs to deploy stacks.

## 3. Deploy (~8 min)

Default deploy creates 2 stacks (Infra + EC2) with LocalExecutor:

```bash
make deploy
# or: cd cdk && npx cdk deploy --all --require-approval never
```

What gets created:
- **AirflowInfra** (~6 min): VPC, 1 NAT Gateway, RDS PostgreSQL (t3.small),
  S3 buckets (logs + DAGs), ECR repo, IAM roles, security groups
- **AirflowEc2** (~2 min): EC2 t3.large with user data script (installs Docker,
  Python, git, Node.js, AWS CLI, deploys helper scripts)

For ECS/Batch executor testing (adds NLB + ECS + Batch stacks):
```bash
make deploy-ecs
# or: cd cdk && npx cdk deploy --all -c executor=ecs --require-approval never
```
This adds ~5 min for the additional 2 stacks.

## 4. Set Up Airflow on EC2 (~10 min)

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

## 6. ECS Executor Testing (Optional, ~40 min total)

To test multi-team ECS executor routing with Fargate workers.
This was validated end-to-end on 2026-03-20 with `alpha_simple_dag`
completing successfully on ECS Fargate in ~200 seconds (includes image pull).

### Step 1: Deploy ECS stacks (~5 min)
```bash
make deploy-ecs
# or: cd cdk && npx cdk deploy --all -c executor=ecs --require-approval never
```
This adds:
- **NLB** (internal, workers call back to Execution API via this)
- **AirflowEcs** stack: alpha-cluster + beta-cluster, Fargate task definitions
- **AirflowBatch** stack: alpha + beta compute environments and job queues

### Step 2: Build and push worker image (~30 min)
The worker image must be built from source (Airflow 3.x isn't on PyPI yet).
This is the slowest step — Breeze builds Airflow with all extras from source.

```bash
# On EC2 (via interactive SSM session):
af rebuild
```

What happens under the hood:
1. `breeze prod-image build --python 3.12` — Docker multi-stage build (~25 min)
2. Tag image for ECR
3. `docker push` to ECR (~5 min for a 4GB image)

**Known issue**: `breeze` is installed by `uv tool install` into `~/.local/bin`,
which isn't on PATH in non-interactive SSM shells. When running via `ssm send-command`,
prepend the PATH: `export PATH=/home/ec2-user/.local/bin:$PATH`

If running via `ssm send-command`, the default 1800s timeout may not be enough.
The Docker build itself continues even if the SSM command times out. You can
tag and push manually afterward:
```bash
# Check if image exists
docker images | grep airflow

# Tag for ECR
docker tag ghcr.io/apache/airflow/main/prod/python3.12:latest \
  <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/airflow-ecs-worker:latest

# Login and push
aws ecr get-login-password --region <REGION> | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com
docker push <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/airflow-ecs-worker:latest
```

### Step 3: Upload multi-team DAGs to S3
DAGs go into team-prefixed paths in the DAG bucket:
```
s3://<dag-bucket>/team_alpha/   → team_alpha_dags bundle
s3://<dag-bucket>/team_beta/    → team_beta_dags bundle
s3://<dag-bucket>/shared/       → shared_dags bundle
```

Example (using test DAGs from the airflow fork):
```bash
DAG_BUCKET=$(aws ssm get-parameter --name /airflow-test/dag-bucket --query Parameter.Value --output text)
aws s3 sync ./dags/team_alpha/ "s3://${DAG_BUCKET}/team_alpha/"
aws s3 sync ./dags/team_beta/ "s3://${DAG_BUCKET}/team_beta/"
aws s3 sync ./dags/shared/ "s3://${DAG_BUCKET}/shared/"
```

### Step 4: Switch to ECS executor config
The config template is at `configs/ecs-multi-team.cfg`. Key differences from
LocalExecutor:

| Setting | LocalExecutor | ECS Multi-team |
|---------|--------------|----------------|
| `executor` | `LocalExecutor` | `LocalExecutor;team_alpha=...AwsEcsExecutor;team_beta=...AwsEcsExecutor` |
| `multi_team` | not set | `True` |
| `execution_api_server_url` | `http://localhost:8080/execution/` | `http://<NLB_DNS>:8080/execution/` |
| `dag_bundle_config_list` | default | per-team S3 bundles |
| team executor sections | none | `[team_alpha=aws_ecs_executor]`, `[team_beta=aws_ecs_executor]` |

The config uses `${VAR}` placeholders that get expanded by `env.sh` on EC2.
Generate the final config on EC2 where all SSM params are available:
```bash
# On EC2:
source /opt/airflow-scripts/env.sh
# Then either copy and envsubst, or use the write-ecs-config helper
```

### Step 5: Create teams and restart
```bash
# On EC2:
source ~/airflow-venv/bin/activate
airflow teams create team_alpha
airflow teams create team_beta
af restart
```

Verify DAGs are loaded (may take ~30s for dag-processor refresh):
```bash
airflow dags list | grep simple
# Should show: alpha_simple_dag, beta_simple_dag, shared_simple_dag
```

### Step 6: Trigger a test run
```bash
airflow dags unpause alpha_simple_dag
airflow dags trigger alpha_simple_dag
```

Monitor via API:
```bash
curl -s http://localhost:8080/api/v2/dags/alpha_simple_dag/dagRuns | python3 -m json.tool
```

Check ECS for the Fargate task:
```bash
aws ecs list-tasks --cluster alpha-cluster
aws ecs describe-tasks --cluster alpha-cluster --tasks <task-arn> \
  --query 'tasks[0].containers[0].exitCode'
# exitCode: 0 = success
```

Expected behavior:
- **team_alpha/team_beta DAGs** → run on ECS Fargate (remote workers)
- **shared DAGs** → run on LocalExecutor (on EC2)
- First run is slow (~200s) due to 4GB image pull; subsequent runs are faster

### Revert to LocalExecutor
To go back to LocalExecutor after testing:
```bash
# On EC2: re-run setup-airflow.sh (rewrites config) or manually edit airflow.cfg
af restart
```

## 7. Tear Down

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

With ECS executor (adds):

| Resource | Monthly Cost |
|----------|-------------|
| NLB | ~$18 |
| Fargate tasks | pay-per-use (pennies per run) |
| **Total with ECS** | **~$140/mo (~$4.60/day)** |

Stop the EC2 instance when not in use to save on compute.
Destroy the whole stack when done to pay nothing.

## IAM Identity Center (SSO) — Optional

For temporary credentials instead of long-lived access keys:

1. AWS Console → search **IAM Identity Center** → Enable
2. Create an SSO user
3. Note the start URL (format: `https://d-xxxxxxxxxx.awsapps.com/start`)
4. Configure locally:
```bash
aws configure sso
# SSO start URL: https://d-xxxxxxxxxx.awsapps.com/start  (NOT your console sign-in URL)
# SSO region: us-west-2
# Select your account and role
```
5. Authenticate: `aws sso login --profile <profile-name>`

> **Common mistake**: Using your console sign-in URL
> (`https://ACCOUNT_ID.signin.aws.amazon.com/console`) as the SSO start URL.
> The SSO start URL has a different format with a `d-` prefix.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `SessionManagerPlugin is not found` | `brew install --cask session-manager-plugin` |
| pnpm install fails with EACCES | Fixed in setup script — uses `sudo npm install -g pnpm` |
| CDK bootstrap fails | Check `aws sts get-caller-identity` returns correct account |
| Setup script hangs | The git clone + UI build takes ~10 min — be patient |
| Port 8080 not responding after setup | Wait 30s for API server startup, then check `af status` on EC2 |
| `breeze: command not found` via SSM | PATH missing `~/.local/bin`. Prefix with `export PATH=/home/ec2-user/.local/bin:$PATH` |
| `aws configure` shows SSO prompts | Corrupted `~/.aws/config` from aborted SSO setup. Delete `~/.aws/config` and re-run `aws configure --profile default` |
| Worker image build slow | Breeze builds from source (~25 min). Normal for Airflow 3.x pre-release |
| SSM send-command times out during build | Docker build continues after timeout. Check `docker images` — if the image is there, just tag and push manually |
| DAGs not appearing after S3 upload | Wait for dag-processor refresh cycle (~30s). Check `airflow dags list` |
| ECS task stuck in PENDING | Image pull takes time (~2 min for 4GB). Check task status with `aws ecs describe-tasks` |
| ECS task STOPPED with exit code 1 | Check CloudWatch logs in `/airflow/alpha-worker` or `/airflow/beta-worker` log groups |
| `ecr:DescribeImages` access denied | EC2 role may need additional ECR permissions — check IAM policy |
