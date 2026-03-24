# CDK Learnings — Airflow on EC2

Observations from building and operating this CDK project across multiple
deploy/test/teardown cycles in March 2026.

## What Went Well

### Stack composition
4 independent stacks (Infra/EC2/ECS/Batch) with clear boundaries. Infra deploys
once (~8 min), EC2 updates fast (~2 min). ECS/Batch are additive and optional.
This made iterating on compute config painless without touching the slow VPC/RDS
provisioning.

### SSM params as runtime config
Scripts on EC2 read infra config (DB endpoint, bucket names, subnets) at runtime
via `env.sh` pulling from SSM Parameter Store. Nothing hardcoded. Made it trivial
to switch between executor configs without redeploying CDK stacks.

### Conditional stacks via context flags
`-c executor=ecs` adds ECS/Batch stacks. No flag = just Infra + EC2 with
LocalExecutor. Clean separation — you only pay for what you use.

### Clean teardown
`make destroy` tears down everything. `removalPolicy: DESTROY` +
`autoDeleteObjects: true` on S3 means no orphaned buckets. Full account cleanup
in minutes.

### Multi-stack suffix support
The `suffix` context parameter allows deploying parallel environments
(`-c suffix=celery`) without resource naming conflicts. Each suffix gets its own
VPC, RDS, S3 buckets, and SSM parameter namespace.

## What Needs Improvement

### 1. Cross-stack export dependency (blocking)
CDK exports (VPC ID, NLB ARN) create hard CloudFormation dependencies. Can't
remove the NLB from InfraStack while Ec2Stack references its export. CloudFormation
deploys InfraStack before Ec2Stack, so the ordering prevents cleanup.

**Fix:** Use SSM parameters instead of CloudFormation exports for cross-stack
references. SSM params can be deleted independently.

### 2. Missing aiobotocore in setup script
Deferrable AWS operators (`GlueJobOperator(deferrable=True)`) silently fail
without `aiobotocore`. The error message ("Trigger failure") gives zero hint
about the missing module — you have to dig into triggerer logs.

**Fix:** Add `uv pip install "providers/amazon[async]"` to setup script.

### 3. No triggerer in service startup
`airflow-ctl.sh` starts api-server, scheduler, dag-processor — but not the
triggerer. Any deferrable operator just hangs forever in "deferred" state.

**Fix:** Add triggerer to the service list in `airflow-ctl.sh`.

### 4. Breeze image build is slow (~30 min)
Building Airflow from source with all extras on t3.large takes 30+ minutes.
The SSM send-command timeout (1800s max) expires before it finishes, but the
Docker build continues in the background. You then need to manually tag and push.

**Fix:** Document the manual tag+push fallback. Consider pre-building images in
CI and pushing to ECR, or caching Docker layers across deploys.

### 5. DB migrations break on branch switches
Switching Airflow branches with different migration histories causes
`Can't locate revision identified by '...'`. Requires dropping and recreating
the schema.

**Fix:** Add an `af reset-db` helper that does `DROP SCHEMA public CASCADE;
CREATE SCHEMA public; airflow db migrate`.

### 6. SSM send-command quoting is fragile
Complex shell commands with nested quotes, heredocs, or variable expansion fail
unpredictably when passed through SSM's JSON parameter format.

**Fix:** Upload scripts to S3 and download+execute on EC2 — which is what we
ended up doing for every non-trivial operation.

## Cost Observations

| Config | Monthly Cost | Daily Cost |
|--------|-------------|-----------|
| LocalExecutor (Infra + EC2) | ~$122 | ~$4.00 |
| + ECS executor (adds NLB) | ~$140 | ~$4.60 |
| Fargate tasks | pay-per-use | pennies/run |
| Glue Python Shell test | $0.01/run | negligible |

Stop EC2 when not in use. Destroy the whole stack when done — zero lingering costs.
