# Architecture — airflow-ec2

## Overview

`airflow-ec2` deploys a complete Airflow 3.x environment on AWS using CDK. A single
`cdk deploy` creates all infrastructure. SSM into EC2, run setup, and you have Airflow.

**Not for production.** For development, testing, experimentation, demos.

---

## Stack Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Core Stack (deploy once, ~15 min)                      │
│                                                         │
│  ┌─────────┐  ┌──────────┐  ┌─────┐  ┌─────┐  ┌─────┐│
│  │  VPC    │  │ RDS      │  │ S3  │  │ ECR │  │ IAM ││
│  │ 2 AZs  │  │ Postgres │  │logs │  │     │  │     ││
│  │ 2 NATs │  │ 16       │  │dags │  │     │  │     ││
│  └─────────┘  └──────────┘  └─────┘  └─────┘  └─────┘│
│                                                         │
│  ┌──────────────┐  ┌──────────────────────────────────┐│
│  │ Internal NLB │  │ SSM Parameters (/airflow-test/*) ││
│  │ TCP 8080     │  │ DB, ECR, S3, NLB, subnets, SGs   ││
│  └──────────────┘  └──────────────────────────────────┘│
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Airflow Stack (deploy/update ~2 min)                   │
│                                                         │
│  ┌──────────────────────────────────────────────┐      │
│  │  EC2 (t3.large, Amazon Linux 2023)           │      │
│  │                                               │      │
│  │  ┌─────────────┐ ┌───────────┐ ┌───────────┐│      │
│  │  │ api-server  │ │ scheduler │ │dag-process ││      │
│  │  │ :8080       │ │           │ │            ││      │
│  │  └─────────────┘ └───────────┘ └───────────┘│      │
│  │                                               │      │
│  │  Tools: Python 3.12, uv, Docker, Breeze,    │      │
│  │         Git, AWS CLI, psql, Node.js          │      │
│  └──────────────────────────────────────────────┘      │
│                                                         │
│  NLB Target Group → EC2:8080                           │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  ECS Stack (optional, ~30s)                             │
│                                                         │
│  ┌──────────────────┐  ┌──────────────────┐           │
│  │ alpha-cluster    │  │ beta-cluster     │           │
│  │ Fargate tasks    │  │ Fargate tasks    │           │
│  │ 1 vCPU / 2GB    │  │ 1 vCPU / 2GB    │           │
│  └──────────────────┘  └──────────────────┘           │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Batch Stack (optional, ~30s)                           │
│                                                         │
│  ┌──────────────────┐  ┌──────────────────┐           │
│  │ alpha-batch-queue│  │ beta-batch-queue │           │
│  │ Fargate, 16 vCPU │  │ Fargate, 16 vCPU │           │
│  └──────────────────┘  └──────────────────┘           │
└─────────────────────────────────────────────────────────┘
```

---

## Network Design

### VPC: `10.0.0.0/16`
- 2 public subnets (NAT Gateways only)
- 2 private subnets (all compute: EC2, RDS, ECS, Batch, NLB)
- 2 NAT Gateways (one per AZ) for private subnet outbound

### Security Groups (4)

```
ec2Sg:     inbound TCP 8080 from nlbSg       ← API traffic + health checks
           outbound ALL to 0.0.0.0/0         ← git, pip, ECR, AWS APIs

dbSg:      inbound TCP 5432 from ec2Sg       ← DB access from EC2 only

nlbSg:     inbound TCP 8080 from workerSg    ← workers reach Execution API
           outbound TCP 8080 to ec2Sg        ← forward to EC2 + health checks

workerSg:  outbound TCP 8080 to nlbSg        ← Execution API callbacks
           outbound TCP 443 to 0.0.0.0/0     ← ECR, S3, AWS APIs via NAT
```

**No public endpoints.** UI access via SSM port forwarding. No ALB, no ACM cert, no domain needed.

---

## Communication Flow

```
Developer (Mac)
    │
    │ SSM port forward :8080
    ▼
EC2 (api-server :8080)
    │
    ├── scheduler reads serialized DAGs from DB
    ├── dag-processor parses DAGs from S3 bundles
    ├── scheduler submits tasks via ECS RunTask / Batch SubmitJob
    │
    ▼
ECS/Batch Workers (Fargate)
    │
    │ HTTP :8080 via NLB
    ▼
EC2 (Execution API :8080)
    │
    │ PostgreSQL :5432
    ▼
RDS (metadata DB)
```

Workers **never** access the metadata DB directly (Airflow 3.x architecture).
Workers communicate only via the Execution API through the internal NLB.

---

## Access Model

- **No SSH keys** — SSM Session Manager only
- **No public IPs** — everything in private subnets
- **No ALB/domain** — SSM port forwarding for UI
- **IAM-based** — EC2 instance profile, ECS task roles
- **SimpleAuthManager** — all users are admin (dev environment)

---

## Storage

| Resource | Purpose | Lifecycle |
|----------|---------|-----------|
| RDS PostgreSQL 16 | Airflow metadata DB | DESTROY on teardown |
| S3 log bucket | Remote task logs | DESTROY, auto-delete objects |
| S3 DAG bucket | S3DagBundle storage | DESTROY, auto-delete objects |
| ECR repo | Worker container images | DESTROY, keep last 5 images |

---

## Configuration

All runtime config is stored in SSM Parameter Store under `/airflow-test/*`.
EC2 scripts read SSM at runtime — no hardcoded values.

| Parameter | Value |
|-----------|-------|
| `/airflow-test/db-endpoint` | RDS endpoint |
| `/airflow-test/db-secret-arn` | Secrets Manager ARN |
| `/airflow-test/db-name` | `airflow_db` |
| `/airflow-test/ecr-repo` | ECR repository URI |
| `/airflow-test/log-bucket` | S3 log bucket name |
| `/airflow-test/dag-bucket` | S3 DAG bucket name |
| `/airflow-test/nlb-dns` | Internal NLB DNS |
| `/airflow-test/worker-sg` | Worker security group ID |
| `/airflow-test/private-subnets` | Comma-separated subnet IDs |
| `/airflow-test/region` | AWS region |
| `/airflow-test/alpha-cluster` | ECS cluster name |
| `/airflow-test/alpha-task-def` | ECS task definition family |
| `/airflow-test/beta-cluster` | ECS cluster name |
| `/airflow-test/beta-task-def` | ECS task definition family |

---

## Cost Estimate (us-west-2)

| Resource | Hourly | Daily | Monthly |
|----------|--------|-------|---------|
| EC2 t3.large | $0.08 | $1.96 | $60 |
| RDS db.t3.medium (single-AZ) | $0.07 | $1.63 | $50 |
| NAT Gateway × 2 | $0.09 | $2.16 | $65 |
| S3 + ECR | negligible | ~$0.10 | ~$3 |
| NLB | $0.02 | $0.54 | $16 |
| **Total (core)** | **~$0.26** | **~$6.39** | **~$194** |

ECS/Batch tasks are pay-per-use (only when running). Fargate: ~$0.04/vCPU/hr.

**Teardown is free and instant:** `cdk destroy --all --force`
