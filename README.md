# airflow-ec2

Deploy Apache Airflow 3.x on your AWS account in minutes. CDK-based. Not for production.

**Deploy in ~15 min. Tear down instantly. ~$6/day while running.**

## Quick Start

### Prerequisites

- AWS CLI configured (`aws sts get-caller-identity` works)
- Node.js 18+
- CDK bootstrapped: `cd cdk && npx cdk bootstrap`

### Deploy

```bash
make deploy             # deploys VPC, RDS, S3, EC2 (~15 min first time)
```

### Connect

```bash
make tunnel             # port-forward 8080 via SSM
# Then open http://localhost:8080

make ssh                # shell access via SSM
```

### First-time setup on EC2

```bash
sudo su - ec2-user
bash /opt/airflow-scripts/setup-airflow.sh    # ~10 min
```

This clones Airflow, installs it, builds the UI, configures LocalExecutor with
RDS + S3, and starts all services.

### Tear down

```bash
make destroy            # removes everything, no lingering costs
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
