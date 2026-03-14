# Market Research — Airflow on AWS Deployment Tools

## Date: 2026-03-14

## Executive Summary

There is **no maintained, one-command tool** for deploying Apache Airflow on AWS for
development/testing. The most popular project (Turbine, 378 stars) was archived in 2021.
**Zero CDK projects exist.** Nothing supports Airflow 3.x. `airflow-ec2` fills this gap.

---

## Existing Projects

### CloudFormation

| Project | Stars | Status | Notes |
|---------|-------|--------|-------|
| [villasv/aws-airflow-stack (Turbine)](https://github.com/villasv/aws-airflow-stack) | 378 | **Archived Oct 2021** | The closest to one-click deploy. EC2 + auto-scaling workers + SQS + RDS + S3 + EFS. Maintainer recommends CDK/Terraform/Astronomer. |

### Terraform

| Project | Stars | Status | Notes |
|---------|-------|--------|-------|
| [nicor88/aws-ecs-airflow](https://github.com/nicor88/aws-ecs-airflow) | 161 | Low activity | ECS Fargate + Celery + Flower. Terraform + Docker. |
| [PowerDataHub/terraform-aws-airflow](https://github.com/PowerDataHub/terraform-aws-airflow) | 84 | Low activity | EC2 + RDS + SQS as Celery broker. |
| [datarootsio/terraform-aws-ecs-airflow](https://github.com/datarootsio/terraform-aws-ecs-airflow) | 60 | Low activity | ECS Fargate via Terraform. |
| [unruly/terraform-aws-airflow](https://github.com/unruly/terraform-aws-airflow) | 24 | Low activity | EC2 + PostgreSQL. |

### CDK

**Zero meaningful projects.** AWS `aws-cdk-examples` repo has no Airflow example.

### Pulumi

**Zero projects found.**

### Docker-based

| Project | Stars | Status | Notes |
|---------|-------|--------|-------|
| [puckel/docker-airflow](https://github.com/puckel/docker-airflow) | 3,800 | **Abandoned Feb 2020** | Python 3.7, Airflow 1.x. Historically the most popular. |
| [aws/aws-mwaa-local-runner](https://github.com/aws/aws-mwaa-local-runner) | 804 | Active | Local dev only, not for EC2 deployment. MWAA-specific. |

---

## How People Deploy Airflow on AWS Today

1. **Docker-compose on EC2** — Most common for dev. Manual setup on a t3.medium+.
2. **ECS Fargate with Terraform** — More production-like. Uses community Terraform modules.
3. **EKS + Helm Chart** — For K8s teams. Official Airflow Helm chart.
4. **AWS MWAA** — Managed service. Can't test custom code/executors/providers.
5. **Astronomer/Astro CLI** — Commercial. Polished local dev, not AWS deployment.
6. **Breeze** — Official dev tool. Local Docker-only, no cloud deployment.

---

## Pain Points (from community)

1. **No bridge between local and cloud** — Breeze is local-only. MWAA is managed. Nothing in between.
2. **Provider testing requires real AWS** — 81 system test files for Amazon provider, all need real AWS resources. No sandbox.
3. **Moto gap** — Unit tests use moto (mocked AWS). System tests hit real AWS. Nothing in between for integration testing.
4. **Memory requirements** — Docker-compose needs 4-8GB RAM. Docker for Mac struggles.
5. **Recovery is destructive** — Official docs say "clean up and restart from scratch" for most problems.
6. **No Airflow 3.x support** — All existing deployment tools target Airflow 1.x or 2.x.

---

## Competitor Analysis (Other Orchestrators)

| Tool | Self-hosted AWS Deploy Tool | Managed Offering |
|------|---------------------------|------------------|
| Airflow | None (all archived/stale) | AWS MWAA |
| Dagster | None | Dagster Cloud |
| Prefect | None | Prefect Cloud |

**All three ecosystems push users toward managed offerings.** None provide a self-hosted AWS deployment tool.

---

## Airflow Testing Infrastructure

### How Airflow tests AWS providers today

The official Airflow repo has a tiered testing approach:

1. **Unit tests** — Required for all PRs. Run locally or in Breeze. AWS provider unit tests
   heavily use `moto` for mocking (301 unit test files, 69 using moto/mock_aws).

2. **Integration tests** — Run in Breeze. Require additional services (Postgres, MySQL, etc.).

3. **System tests** — Run against real external services. 81 system test files for the Amazon
   provider alone, covering: ECS, EKS, S3, Lambda, SageMaker, Bedrock, RDS, DynamoDB,
   Redshift, EMR, Athena, Glue, Step Functions, SNS, SQS, and many more.

4. **Helm unit tests** — Verify chart rendering.

5. **Kubernetes tests** — Verify K8s deployment and KubernetesPodOperator.

### The system test gap

System tests require a real AWS account with appropriate permissions and create real (billable)
resources. There is no sandboxed or cost-free way to run them. There is no CI pipeline that
automatically runs system tests on PRs — they must be run manually by contributors with AWS
accounts.

To run them: `pytest --system providers/amazon/tests/system/amazon/aws/example_ecs.py`

The Amazon provider has utility helpers at `providers/amazon/tests/system/amazon/aws/utils/ec2.py`
for creating VPCs/subnets/NAT gateways within system test DAGs.

### LocalStack adoption

Despite LocalStack having 64,700 stars, only a handful of tiny repos (5 stars max) combine
it with Airflow. LocalStack is not used in the official Airflow test suite. LocalStack free
tier mocks API responses but doesn't run real containers (needed for ECS executor testing).
LocalStack Pro can run containers but requires a license and Docker-in-Docker.

---

## The Gap `airflow-ec2` Fills

1. **First CDK project** for Airflow on AWS
2. **First tool supporting Airflow 3.x**
3. **First tool with developer UX** beyond just infrastructure (the `af` CLI)
4. **First tool with branch-switching workflow** for iterative development
5. **Battle-tested** — 19 deployment issues already solved
6. **Composable** — Optional ECS/Batch stacks for executor testing

---

## Key Insights

### Why CDK over Terraform?
- TypeScript — type-safe, composable, IDE support
- L2/L3 constructs reduce boilerplate vs. CloudFormation
- Same language as the CDK community is moving toward
- Stack separation is natural (infra vs. compute)

### Why EC2 over ECS for the Airflow server?
- Simpler mental model — one box running scheduler + api-server + dag-processor
- Easy to SSM in and debug
- Can run Breeze inside EC2 for image builds
- Matches how most people develop locally (single machine)
- ECS/Batch/K8s are for the *workers*, not the server

### Why not just use MWAA?
- Can't test unreleased Airflow versions (3.x)
- Can't test custom executors (ECS, Batch)
- Can't test provider changes before they're published
- Can't debug the scheduler/dag-processor internals
- Can't modify airflow.cfg freely
- Locked to MWAA-supported configurations
