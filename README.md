# airflow-ec2

Deploy Apache Airflow 3.x on your AWS account in minutes. CDK-based. Not for production.

**Deploy in ~15 min. Tear down instantly. ~$6/day while running.**

## Quick Start

### Prerequisites

- AWS CLI configured (`aws sts get-caller-identity` works)
- Node.js 18+
- CDK bootstrapped: `cd cdk && npx cdk bootstrap`

### Deploy with default settings (LocalExecutor, apache/airflow main)

```bash
make deploy
make ssh              # then run: bash /opt/airflow-scripts/setup-airflow.sh
make tunnel           # open http://localhost:8080
```

### Deploy with a specific branch/fork

```bash
make deploy REPO=https://github.com/yourfork/airflow.git BRANCH=my-feature
make ssh              # then run: bash /opt/airflow-scripts/setup-airflow.sh
```

### Switch branches (no redeploy needed)

```bash
# From your laptop:
make switch-branch BRANCH=another-feature

# Or from EC2 shell:
af switch another-feature
```

### Switch executor (no redeploy needed for local, deploy-ecs needed first for ECS)

```bash
# From EC2 shell:
af switch-executor ecs    # switches to ECS multi-team mode
af switch-executor local  # back to LocalExecutor
```

### Tear down

```bash
make destroy
```

## Day-to-day (on EC2)

The `af` command is available in every shell:

```
af status              Check service health
af restart             Restart all services
af logs                Tail all logs
af logs scheduler      Tail specific service

af switch <branch>     Switch Airflow branch, rebuild, restart
af deploy-dags         Create test DAGs + upload to S3

af db                  Open psql to metadata DB
af db-reset            Drop DB, recreate, migrate
af config              Show airflow.cfg
af dags                List DAGs
af tunnel              Show SSM tunnel command
```

## Architecture

```
You (laptop) ──SSM tunnel──▶ EC2 (api-server + scheduler + dag-processor)
                                  │
                                  ├──▶ RDS PostgreSQL (metadata)
                                  └──▶ S3 (logs + DAGs)
```

Everything runs in private subnets. No public endpoints. No SSH keys. SSM-only access.

## Stacks

| Stack | What | Deploy time | Default |
|-------|------|-------------|---------|
| AirflowInfra | VPC, RDS, S3, ECR, NLB, IAM | ~15 min | Yes |
| AirflowEc2 | EC2 instance + scripts | ~2 min | Yes |
| AirflowEcs | ECS clusters + task defs | ~30s | Opt-in |
| AirflowBatch | Batch compute + job queue | ~30s | Opt-in |

## Cost

~$6/day while running (EC2 + RDS + NAT Gateways).
`make destroy` removes everything — no lingering costs.

## Advanced: ECS/Batch Executor Testing

To test multi-team ECS/Batch executors with real Fargate workers:

```bash
make deploy-ecs         # deploys all 4 stacks including ECS + Batch
```

Then on EC2, update your Airflow config to use the ECS executor.
See [configs/ecs-multi-team.cfg](configs/ecs-multi-team.cfg) for a reference config.

```
af rebuild              Build + push worker image to ECR
af ecs-tasks            List running ECS tasks
af batch-jobs           List running Batch jobs
af teams                List teams
af ecr-login            Authenticate Docker to ECR
```

## Docs

- [Architecture](docs/DESIGN.md) — Full architecture, security groups, IAM
- [EC2 Setup](docs/EC2_SETUP.md) — Script reference
- [Troubleshooting](docs/TROUBLESHOOTING.md) — 19 solved deployment issues
- [Example Configs](configs/) — LocalExecutor + ECS multi-team configs
- [Specs](specs/) — Research, architecture decisions, roadmap

## License

Apache 2.0
