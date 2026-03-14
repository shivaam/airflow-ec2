# airflow-ec2

Deploy Apache Airflow 3.x on your AWS account in minutes. CDK-based. Not for production.

## What is this?

A one-command deployment of a complete Airflow environment on EC2 for development,
testing, and experimentation. No SSH keys, no public endpoints, no domain needed.

**Deploy in ~15 min. Tear down instantly. ~$6/day while running.**

## Quick Start

### Prerequisites

- AWS CLI configured (`aws sts get-caller-identity` works)
- Node.js 18+
- CDK bootstrapped: `cd cdk && npx cdk bootstrap`

### Deploy

```bash
cd cdk
npm install
npm run build
npm run deploy          # deploys all stacks
```

### Connect

```bash
# Get instance ID
INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name AirflowEc2 \
  --query "Stacks[0].Outputs[?OutputKey=='Ec2InstanceId'].OutputValue" --output text)

# Shell access
aws ssm start-session --target $INSTANCE_ID

# UI access (port forward)
aws ssm start-session --target $INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
# Then open http://localhost:8080
```

### First-time setup on EC2

```bash
sudo su - ec2-user
bash /opt/airflow-scripts/setup-airflow.sh    # ~10 min
```

### Tear down

```bash
cd cdk
npm run destroy         # removes everything
```

## Day-to-day (on EC2)

The `af` command is available in every shell:

```
af status              Check service health
af restart             Restart all services
af logs                Tail all logs
af logs scheduler      Tail specific service

af switch <branch>     Switch branch, rebuild, restart
af rebuild             Build + push worker image to ECR
af deploy-dags         Create test DAGs + upload to S3

af db                  Open psql to metadata DB
af db-reset            Drop DB, recreate, migrate
af config              Show airflow.cfg
af teams               List teams
af dags                List DAGs
af ecs-tasks           List running ECS tasks
af batch-jobs          List running Batch jobs
af tunnel              Show SSM tunnel command
```

## Stacks

| Stack | What | Deploy time | Required |
|-------|------|-------------|----------|
| AirflowInfra | VPC, RDS, S3, ECR, NLB, IAM | ~15 min | Yes |
| AirflowEc2 | EC2 instance + scripts | ~2 min | Yes |
| AirflowEcs | ECS clusters + task defs | ~30s | Optional |
| AirflowBatch | Batch compute + job queue | ~30s | Optional |

Deploy individual stacks:

```bash
npm run deploy:ecs      # just ECS
npm run deploy:batch    # just Batch
npm run deploy:ec2      # just EC2 (replaces instance)
```

## Architecture

```
You (Mac) ──SSM tunnel──▶ EC2 (api-server + scheduler + dag-processor)
                              │
                              ├──▶ RDS PostgreSQL (metadata)
                              ├──▶ S3 (logs + DAGs)
                              │
                              ├──scheduler──▶ ECS RunTask ──▶ Fargate worker
                              └──scheduler──▶ Batch SubmitJob ──▶ Fargate worker
                                                                      │
                                                   NLB ◀── Execution API callback
```

Everything runs in private subnets. No public endpoints. SSM-only access.

## Cost

~$6/day while running (EC2 + RDS + NAT Gateways). ECS/Batch tasks are pay-per-use.
`npm run destroy` removes everything — no lingering costs.

## Docs

- [Architecture](docs/DESIGN.md) — Full architecture, security groups, IAM
- [EC2 Setup](docs/EC2_SETUP.md) — Script reference
- [Troubleshooting](docs/TROUBLESHOOTING.md) — 19 solved deployment issues
- [Specs](specs/) — Research, architecture decisions, roadmap

## License

Apache 2.0
