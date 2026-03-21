# Known Issues

## 1. CDK Cross-Stack Export Dependency Prevents NLB Removal

**Status:** Open
**Discovered:** 2026-03-20

### Problem

When deploying with `-c executor=ecs`, the InfraStack creates an NLB and exports
its ARN/DNS for use by the Ec2Stack (NLB target registration) and ECS/Batch stacks.

After destroying the ECS/Batch stacks and redeploying without `-c executor=ecs`,
CloudFormation refuses to update the InfraStack because it tries to remove exports
that are still referenced by the Ec2Stack:

```
Cannot delete export AirflowInfra:ExportsOutputRefNlbBCDB97FE...
  as it is in use by AirflowEc2
```

CDK deploys InfraStack before Ec2Stack (because Ec2Stack depends on InfraStack),
so it can't remove the NLB export before Ec2Stack stops referencing it.

### Impact

- The NLB stays deployed (~$18/month) even after ECS/Batch stacks are destroyed
- The stack is stuck in `UPDATE_ROLLBACK_COMPLETE` state until the exports are freed

### Workaround

For now, keep the NLB when switching between executor modes. It's idle but present.

### Potential Fixes

1. **Use SSM parameters instead of CloudFormation exports** for the NLB ARN/DNS.
   SSM params can be deleted independently without cross-stack dependency issues.
   The Ec2Stack already looks up the NLB by ARN (`fromNetworkLoadBalancerAttributes`),
   so reading from SSM instead of a stack export would be straightforward.

2. **Two-phase deploy**: First deploy Ec2Stack exclusively to remove NLB target
   references, then deploy InfraStack to remove the NLB. Requires CDK `--exclusively`
   flag and careful ordering.

3. **Always create the NLB** (even with LocalExecutor) but skip the listener/target
   registration. This avoids the export removal issue but wastes ~$18/month.

### Files Involved

- `cdk/lib/infra-stack.ts` — Creates NLB conditionally, exports ARN/DNS
- `cdk/lib/ec2-stack.ts` — Imports NLB ARN from InfraStack outputs
- `cdk/lib/loadbalancers.ts` — NLB construction and target registration

---

## 2. `aiobotocore` Not Installed for Deferrable AWS Operators

**Status:** Resolved (manual install)
**Discovered:** 2026-03-20

### Problem

When using `GlueJobOperator(deferrable=True)`, the triggerer crashes with:
```
ModuleNotFoundError: No module named 'aiobotocore'
```

The async AWS client library is required by `AwsBaseWaiterTrigger` but is not
installed as part of the standard `apache-airflow-providers-amazon` package
installation via `uv pip install ./providers/amazon`.

### Impact

All deferrable AWS operators fail silently — the trigger exits with an error,
and the task gets a generic `TaskDeferralError("Trigger failure")` instead of
the actual AWS error. This makes it impossible to distinguish between missing
dependencies and actual operator bugs.

### Fix

```bash
source ~/airflow-venv/bin/activate
uv pip install aiobotocore
```

### Root Cause

The `aiobotocore` package is listed as an optional dependency in the Amazon
provider (`[async]` extra), not a required dependency. When installing from
source with `uv pip install ./providers/amazon`, the async extras are not
included by default.

### Recommendation

Add `aiobotocore` to the setup script (`ec2-scripts/setup-airflow.sh`) or
install the provider with the async extra:
```bash
uv pip install "./providers/amazon[async]"
```
