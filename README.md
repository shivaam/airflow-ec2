# airflow-ec2

Deploy Apache Airflow 3.x on your AWS account in minutes. CDK-based, for development and testing.

**Deploy in ~15 min. Tear down instantly. ~$6/day.**

## Quick Start

**Prerequisites:** AWS CLI configured, Node.js 18+, [SSM plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)

```bash
# One-time: bootstrap CDK
cd cdk && npx cdk bootstrap

# Deploy (default: apache/airflow main, LocalExecutor)
make deploy

# Or deploy a specific fork/branch
make deploy REPO=https://github.com/yourfork/airflow.git BRANCH=my-feature

# SSH in and run first-time setup (~10 min)
make ssh
# on EC2:  bash /opt/airflow-scripts/setup-airflow.sh

# Access Airflow UI
make tunnel
# open http://localhost:8080
```

## Switching Branches

No redeploy needed. Stops services, checks out branch, reinstalls, rebuilds UI, restarts.

```bash
# From laptop
make switch-branch BRANCH=another-feature

# Or from EC2
af switch another-feature

# Switch to a different fork
af switch my-feature https://github.com/otherfork/airflow.git
```

## Switching Executors

Switch between LocalExecutor and ECS multi-team executor at runtime. Regenerates `airflow.cfg` and restarts.

```bash
# Deploy with ECS stacks (needed once for ECS executor)
make deploy-ecs

# On EC2: switch between executors
af switch-executor ecs      # multi-team ECS Fargate workers
af switch-executor local    # back to LocalExecutor
```

## On EC2: the `af` CLI

```
af status                 Service health + port + DB check
af restart                Restart all services
af logs [service]         Tail logs (api-server, scheduler, dag-processor)
af switch <branch>        Switch Airflow branch
af switch-executor <type> Switch executor (local|ecs)
af deploy-dags            Upload test DAGs to S3
af rebuild                Build + push worker image to ECR
af db                     psql into metadata DB
af config                 Show airflow.cfg
af dags                   List DAGs
af teams                  List teams
af ecs-tasks              List running ECS tasks
af tunnel                 Show SSM tunnel command
```

## Architecture

```
Laptop ──SSM tunnel──> EC2 (api-server + scheduler + dag-processor)
                            |
                            |──> RDS PostgreSQL (metadata)
                            |──> S3 (DAG bundles + logs)
                            |──> ECS Fargate (worker tasks, optional)
```

Private subnets only. No public endpoints. No SSH keys. SSM Session Manager access.

## Stacks

| Stack | Resources | Deploy time | When |
|-------|-----------|-------------|------|
| AirflowInfra | VPC, RDS, S3, ECR, IAM, NLB | ~6 min | Always |
| AirflowEc2 | EC2 t3.large + scripts | ~2 min | Always |
| AirflowEcs | 2 ECS clusters + task defs | ~30s | `make deploy-ecs` |
| AirflowBatch | 2 Batch compute envs + queues | ~30s | `make deploy-ecs` |

## Makefile Reference

| Command | What |
|---------|------|
| `make deploy` | Deploy Infra + EC2 (LocalExecutor) |
| `make deploy-ecs` | Deploy all 4 stacks (+ ECS + Batch) |
| `make destroy` | Tear down everything |
| `make ssh` | SSM shell into EC2 |
| `make tunnel` | Port-forward 8080 for Airflow UI |
| `make status` | Check instance health |
| `make setup` | Run first-time setup via SSM (remote) |
| `make switch-branch BRANCH=x` | Switch Airflow branch via SSM |
| `make switch-executor EXECUTOR=x` | Switch executor via SSM |
| `make run CMD="..."` | Run any command on EC2 via SSM |

All targets accept `SUFFIX=name` for multi-stack deployments and `REPO=url BRANCH=name` for fork/branch selection.

## Cost

~$6/day while running (EC2 t3.large + RDS t3.small + NAT Gateway). ECS/Batch workers are pay-per-use on top.

`make destroy` removes everything. No lingering costs.

## Docs

- [Getting Started](docs/GETTING_STARTED.md) -- Step-by-step with timing and troubleshooting
- [EC2 Setup & Scripts](docs/EC2_SETUP.md) -- What each script does
- [Known Issues](docs/KNOWN_ISSUES.md) -- Current limitations and workarounds
- [Architecture](specs/ARCHITECTURE.md) -- VPC, security groups, IAM, cost breakdown
- [Example Configs](configs/) -- LocalExecutor and ECS multi-team airflow.cfg

## License

Apache 2.0
