# Plan — airflow-ec2

## Origin

This project started during development of ExecuteCallback support for the AWS ECS Executor
in Apache Airflow. The work lives on `feature/ecs-executpr` in `shivaam/airflow`:

- `38f8750` — Add ExecuteCallback support to AWS ECS Executor (ecs_executor.py, utils.py,
  version_compat.py, tests — 76 passing)
- `90a7bb3` — Add container-side ExecuteCallback handling in execute_workload.py so
  container-based executors (ECS, Batch, K8s) can run callback workloads in-process
  via execute_callback_workload() without needing the execution API server

To test this end-to-end, we needed real ECS infrastructure — not mocks. The CDK code was
originally built inside the airflow repo on the `test/multi_team` branch under
`dev/ecs-executor-cdk/`. It was used to deploy and test multi-team ECS/Batch executors
on real AWS infrastructure.

The CDK TypeScript source files were initially not committed to git (CDK's default .gitignore
excludes them). Only the synthesized CloudFormation templates in `cdk.out/` and the EC2 helper
scripts were tracked. The source was later committed and extracted into this standalone project.

The project was then reframed: instead of being specific to executor testing, it should be a
**generic tool for deploying Airflow on EC2** — useful for any development, testing, or
experimentation scenario.

## Vision

Deploy a working Airflow 3.x environment on your AWS account in minutes. One CDK deploy,
SSM in, run setup — done. Tear down when finished. Not production. For development,
testing, experimentation.

---

## What We Have Today

### Infrastructure (CDK, 4 stacks, 12 TypeScript files)

**Core/Infra stack:**
- VPC (2 AZs, 2 NATs, public + private subnets)
- RDS PostgreSQL 16 (single-AZ, encrypted, auto-delete)
- S3 buckets (logs + DAGs, auto-delete)
- ECR repository (airflow-ecs-worker, keep last 5 images)
- Internal NLB (TCP 8080, worker traffic only)
- IAM roles (EC2, ECS exec, task)
- 4 security groups (EC2, DB, NLB, worker)
- SSM parameters (all config under /airflow-test/*)

**Airflow/EC2 stack:**
- EC2 t3.large, Amazon Linux 2023, 50GB gp3
- SSM-only access (no SSH keys, no public IP)
- UserData: Python 3.12, uv, Docker, Git, AWS CLI, psql, Node.js
- Scripts deployed via S3 asset → /opt/airflow-scripts/

**ECS stack (optional):**
- 2 ECS clusters (alpha, beta) for multi-team executor testing
- 2 Fargate task definitions (1 vCPU, 2GB)
- CloudWatch log groups

**Batch stack (optional):**
- 2 Fargate compute environments (max 16 vCPUs each)
- 2 job queues + job definitions
- CloudWatch log groups

### EC2 Scripts (7 files, battle-tested)

| Script | Purpose |
|--------|---------|
| `env.sh` | Shared config: reads SSM params, DB creds, activates venv |
| `setup-airflow.sh` | One-shot setup: clone, install, build UI, config, DB, teams, DAGs, start |
| `airflow-ctl.sh` | Service manager: start/stop/restart/status/logs/db-reset |
| `airflow-cli-helpers.sh` | `af` CLI with tab completion (20+ commands) |
| `deploy-dags.sh` | Create test DAGs + upload to S3 |
| `rebuild-worker-image.sh` | Breeze build + ECR push |
| `switch-branch.sh` | Full branch switch: stop → checkout → install → build → migrate → rebuild → start |

### Documentation
- DEPLOYMENT_LOG.md — 19 issues encountered and resolved
- DESIGN.md — Full architecture with security group rules, IAM policies
- EC2_ENV_SETUP.md — Script reference
- BUNDLE_SYNC_BUG.md — Root cause analysis of session corruption bug
- README.md — Quick start and day-to-day commands

### Battle-Tested Issues (19 solved)
1. SG descriptions reject non-ASCII
2. Cloud desktop IP detection fails
3. ACM cert requires custom domain
4. RDS Multi-AZ takes 20 min (switched to single-AZ)
5. Missing asyncpg driver
6. `airflow users create` removed in 3.x
7. Wrong SimpleAuthManager import path
8. React UI not built → TemplateNotFound
9. Node.js not installed
10. npm peer dependency conflict (React 19 vs @visx)
11. pkill not killing gunicorn workers
12. ECR blocks destroy if images exist
13. SSM port forwarding before Airflow starts
14. Stack name mismatch after refactor
15. Wrong ECS executor import path
16. Missing per-team executor config sections
17. LocalExecutor timeout via NLB (use localhost instead)
18. JWT secret mismatch between processes
19. Port 8080 still bound after pkill

---

## Plan

### Phase 1: Extract and restructure (done)
- [x] Create standalone repo (`/workspace/airflow-ec2`)
- [x] Write specs: market research, architecture, plan
- [x] Copy 12 CDK TypeScript files from `origin/test/multi_team:dev/ecs-executor-cdk/lib/`
- [x] Copy 7 EC2 scripts from `origin/test/multi_team:dev/ecs-executor-cdk/ec2_scripts/`
- [x] Copy docs: DESIGN.md, DEPLOYMENT_LOG.md, EC2_ENV_SETUP.md, BUNDLE_SYNC_BUG.md
- [x] Fix CDK asset path (compute.ts: `ec2_scripts` → `../../ec2-scripts`)
- [x] Add .gitignore, README, CLAUDE.md
- [x] Initial commit

### Phase 2: Generalize
- [ ] Rename stacks: InfraStack → CoreStack, Ec2Stack → AirflowStack
- [ ] Make ECS/Batch stacks truly optional (deploy flag or separate command)
- [ ] Make multi-team optional (default to single-team LocalExecutor)
- [ ] Parameterize: instance size, RDS size, region, Airflow branch
- [ ] Add `Makefile` for laptop-side operations (deploy, ssh, destroy, logs, status)

### Phase 3: Polish
- [ ] Move test DAGs from inline heredocs to tracked files in `dags/`
- [ ] Add more test DAGs (basic, callback, deadline, retry, sensors)
- [ ] Improve README with animated GIF / asciicast
- [ ] Add cost estimates and teardown reminders
- [ ] Add auto-stop Lambda (stop EC2 after N hours idle)

### Phase 4: Expand
- [ ] GitHub Actions workflow for CI-triggered deployment
- [ ] Multi-user support (stack name prefix per developer)
- [ ] EKS stack (optional) for KubernetesExecutor testing
- [ ] LocalStack stack (optional) for offline testing
- [ ] Airflow system test runner integration

---

## Use Cases

### 1. Test a PR/branch
```bash
# On EC2:
af switch feature/my-branch
af deploy-dags
# Trigger DAG in UI, check logs
```

### 2. Provider development
Test AWS providers against real S3, ECS, Batch — not moto mocks.

### 3. Executor testing
Real ECS/Batch executor with real Fargate containers. Validate end-to-end:
scheduler → RunTask → worker → Execution API → task complete.

### 4. Feature evaluation
Try multi-team, S3 DAG bundles, new auth managers, execution API changes.

### 5. Bug reproduction
Clean environment matching real deployment topology. Reproduce issues
that don't appear in Breeze/local dev.

### 6. System test runner
Run official Airflow system tests (81 Amazon provider test files) against
real AWS. Currently no easy way to do this.

### 7. Demos/workshops
Spin up, show Airflow 3.x features, tear down. No permanent infrastructure.

---

## Open Questions

1. **Should we support Airflow 2.x?** — Probably not. Focus on 3.x, which is where the gap is.
2. **Should CDK context (AZ lookups) be committed?** — Yes, avoids network calls during synth.
3. **Should we publish to npm/PyPI?** — Not initially. Git clone + cdk deploy is fine.
4. **Should there be a CLI tool?** — Makefile first. CLI later if needed.
5. **License?** — Apache 2.0 (matches Airflow).
