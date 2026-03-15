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
- Default: 2 CDK stacks (Infra + EC2) with LocalExecutor — simple, just works
- Opt-in: ECS + Batch stacks for multi-team executor testing (`make deploy-ecs`)
- 7 EC2 helper scripts with the `af` CLI (setup, services, branch switching, image building, DAG deployment)
- SSM-only access (no SSH keys, no public endpoints)
- Makefile for laptop operations (deploy, ssh, tunnel, destroy)
- Example configs for LocalExecutor and ECS multi-team
- ~$6/day running cost, instant teardown

### What needs work
- Parameterize: instance size, RDS size, region, Airflow branch/repo
- CLI tool for switching between executor configs
- Cost guard (auto-stop EC2 after idle hours)
- Multi-user support (stack name prefix)
- GitHub Actions for CI-triggered deployment
- EKS stack for KubernetesExecutor testing

## Project Structure

```
cdk/              CDK infrastructure (TypeScript)
  lib/            12 source files — stacks + constructs
ec2-scripts/      Scripts deployed to EC2 at /opt/airflow-scripts/
configs/          Example airflow.cfg files (local, ecs-multi-team)
dags/             Test DAGs (synced to S3)
specs/            Research, architecture decisions, roadmap
docs/             Operational docs, troubleshooting
```

## Commands

```bash
make deploy                 # deploy Infra + EC2 (LocalExecutor)
make deploy-ecs             # deploy all 4 stacks (+ ECS + Batch)
make ssh                    # SSM shell into EC2
make tunnel                 # port-forward 8080 for UI
make destroy                # tear down everything
```

## Key Design Decisions

- **CDK over Terraform** — typed, composable, L2 constructs reduce boilerplate
- **EC2 over ECS for the server** — simple mental model, easy to debug via SSM, can run Breeze inside
- **SSM over SSH** — no key management, no public IPs, works through NAT
- **SSM params for config** — scripts read at runtime, nothing hardcoded
- **Breeze for image builds** — builds from source on EC2, pushes to ECR
- **4 stacks** — Infra (slow, deploy once) vs Compute (fast, update often) vs ECS/Batch (optional)
