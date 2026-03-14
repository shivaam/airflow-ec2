# airflow-ec2

## What This Is

A CDK project that deploys Apache Airflow 3.x on EC2 in your AWS account in minutes.
Not for production. For development, testing, experimentation, and demos.

There are **zero maintained tools** for deploying Airflow on AWS for dev/testing.
The most popular one (Turbine, 378 stars) was archived in 2021. No CDK projects exist.
Nothing supports Airflow 3.x. This project fills that gap.

## Current State

We extracted a working, battle-tested deployment from a branch in the apache/airflow fork.
It has been deployed and used successfully. 19 deployment issues were encountered and solved.

### What works today
- 4 CDK stacks: Infra (VPC, RDS, S3, ECR, NLB, IAM), EC2 (Airflow server), ECS (optional), Batch (optional)
- 7 EC2 helper scripts with the `af` CLI (setup, services, branch switching, image building, DAG deployment)
- SSM-only access (no SSH keys, no public endpoints)
- Multi-team ECS/Batch executor testing
- ~$6/day running cost, instant teardown

### What needs work
- Currently hardcoded for multi-team ECS executor testing — needs to be generalized
- ECS/Batch stacks should be truly optional (not deployed by default)
- Default config should be single-team LocalExecutor (simplest useful setup)
- Instance size, RDS size, region, Airflow branch should be parameterized
- Test DAGs are inline heredocs in deploy-dags.sh — should be tracked files in `dags/`
- No Makefile yet for laptop-side operations (deploy, ssh, destroy, status)

## Direction

### Phase 1: Generalize (next)
- Make the default deployment simple: EC2 running Airflow with LocalExecutor
- ECS/Batch stacks become opt-in for executor testing
- Parameterize key settings (instance size, region, Airflow branch/repo)
- Add Makefile for common operations from laptop

### Phase 2: Polish
- Test DAGs as tracked files
- Better README with usage examples
- Cost guard (auto-stop EC2 after idle hours)
- Multi-user support (stack name prefix)

### Phase 3: Expand
- GitHub Actions for CI-triggered deployment
- EKS stack for KubernetesExecutor testing
- Airflow system test runner integration

## Project Structure

```
cdk/              CDK infrastructure (TypeScript)
  lib/            12 source files — stacks + constructs
ec2-scripts/      Scripts deployed to EC2 at /opt/airflow-scripts/
dags/             Test DAGs (synced to S3)
specs/            Research, architecture decisions, roadmap
docs/             Operational docs, troubleshooting
```

## Commands

```bash
cd cdk
npm install && npm run build
npm run deploy              # deploy all stacks
npm run deploy:ec2          # just EC2 (~2 min)
npm run deploy:ecs          # just ECS (~30s)
npm run destroy             # tear down everything
```

## Key Design Decisions

- **CDK over Terraform** — typed, composable, L2 constructs reduce boilerplate
- **EC2 over ECS for the server** — simple mental model, easy to debug via SSM, can run Breeze inside
- **SSM over SSH** — no key management, no public IPs, works through NAT
- **SSM params for config** — scripts read at runtime, nothing hardcoded
- **Breeze for image builds** — builds from source on EC2, pushes to ECR
- **4 stacks** — Infra (slow, deploy once) vs Compute (fast, update often) vs ECS/Batch (optional)
