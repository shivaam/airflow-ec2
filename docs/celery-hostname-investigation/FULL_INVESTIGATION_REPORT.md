# Full Investigation Report: Celery `--celery-hostname` Breaks Task Execution

**Issue:** [GitHub #59707](https://github.com/apache/airflow/issues/59707)
**Reporter:** @CreeperBeatz
**Date:** 2026-03-21 — 2026-03-22
**Status:** Root cause confirmed, fix verified on live EC2

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Bug Description](#2-bug-description)
3. [Environment & Infrastructure](#3-environment--infrastructure)
4. [Investigation Timeline](#4-investigation-timeline)
5. [Root Cause Analysis](#5-root-cause-analysis)
6. [Fork FD Tracing — Definitive Proof](#6-fork-fd-tracing--definitive-proof)
7. [The Fix](#7-the-fix)
8. [EC2 Live Test Logs](#8-ec2-live-test-logs)
9. [Theories Explored & Discarded](#9-theories-explored--discarded)
10. [Infrastructure & Tooling](#10-infrastructure--tooling)
11. [Issues Encountered & Workarounds](#11-issues-encountered--workarounds)
12. [Reproduction Guide](#12-reproduction-guide)
13. [Files & Artifacts](#13-files--artifacts)

---

## 1. Executive Summary

When starting an Airflow Celery worker with `--celery-hostname`, tasks are received by the worker but never executed. They sit in RESERVED state indefinitely with `acknowledged=False`, `worker_pid=None`, `time_start=None`.

**Root cause:** The duplicate hostname check added in provider 3.14.0 (commit `16829d7694`) calls `celery_app.control.inspect().active_queues()` before `worker_main()`. This opens TCP sockets to Redis that register in `kombu.pools` — a process-global registry. When `worker_main()` forks prefork pool workers, children inherit these shared sockets. The consumer-to-pool IPC (needed by `-O fair` scheduling) fails silently because parent and child are reading/writing on the same socket file descriptors.

**Fix:** Use a temporary Celery app for the `inspect()` call, then call `kombu.pools.reset()` in a `finally` block to close all sockets and clear global pool state before `worker_main()` forks.

**Verification:** Fix tested on live EC2 with CeleryExecutor + Redis broker + PostgreSQL backend. Tasks that were permanently stuck now complete in ~2.6 seconds.

---

## 2. Bug Description

### Symptoms

```bash
# Start worker with custom hostname
airflow celery worker --queues default --concurrency 1 --celery-hostname "myworker@%h"
```

1. Worker connects to broker successfully
2. Worker subscribes to correct queues
3. Worker shows `myworker@<hostname> ready.`
4. Tasks ARE received: `Task execute_workload[...] received`
5. Tasks are NEVER executed — no further log output after "received"

### Celery inspect output (bug present)

```json
{
    "id": "5c97cd55-b026-4dbe-9805-faa7de4c7e4c",
    "name": "execute_workload",
    "hostname": "myworker@ip-10-0-2-61.us-west-2.compute.internal",
    "time_start": null,
    "acknowledged": false,
    "worker_pid": null
}
```

- `time_start: null` — execution never started
- `acknowledged: false` — task never acknowledged
- `worker_pid: null` — no pool process picked it up

### What "reserved but not executed" means

With `-O fair` and `task_acks_late=True`, the task lifecycle is:

```
RECEIVED → RESERVED → (dispatch to pool) → STARTED → SUCCESS/FAILURE
```

The task is stuck between RESERVED and STARTED. The consumer received it from the broker and put it in its internal buffer, but never dispatched it to a prefork pool worker.

### Affected versions

- **Introduced in:** celery provider 3.14.0 (commit `16829d7694`)
- **Persists through:** 3.15.2+ (latest at time of investigation)
- **Works in:** celery provider 3.13.1 and earlier

---

## 3. Environment & Infrastructure

### EC2 Test Stack

We deployed a dedicated EC2 stack using the `airflow-ec2` CDK project with multi-stack suffix support:

| Component | Details |
|-----------|---------|
| **Stack name** | `AirflowInfra-celery` + `AirflowEc2-celery` |
| **Instance** | `i-06b68c955cf91ca55` (t3.large, AL2023) |
| **Region** | us-west-2 |
| **Airflow** | 3.2.0.dev0 from source (`investigate/celery-hostname-59707` branch) |
| **Celery Provider** | 3.17.1 from source |
| **Celery** | 5.6.2 |
| **Redis** | 6.2.20 (localhost:6379) |
| **PostgreSQL** | RDS (`airflowinfra-celery-db5d02a0a9-*.us-west-2.rds.amazonaws.com`) |
| **Executor** | CeleryExecutor |
| **Broker** | `redis://localhost:6379/0` |
| **Result Backend** | `db+postgresql://...` (RDS) |

### Test DAG

Simple BashOperator DAG (`test_celery_hostname`) with one task (`say_hello`) on queue `default`:

```python
BashOperator(
    task_id="say_hello",
    bash_command="echo Hello from Celery worker! && hostname && date",
    queue="default",
)
```

---

## 4. Investigation Timeline

### Phase 1: Initial Theories (Discarded)

| Theory | What we thought | Why we discarded it |
|--------|----------------|---------------------|
| **int-to-str** | `args.concurrency` is `int`, should be `str` in options list | Celery handles int coercion fine — worker banner shows correct `concurrency: 1 (prefork)` |
| **Celery library bug** | `worker_main()` + `--hostname` broken in Celery | Standalone Celery script with same setup works fine |
| **`-O fair` + hostname interaction** | Fair scheduling breaks when hostname changes | `-O fair` is fine — the issue is what happens BEFORE `worker_main()` |

### Phase 2: Identify the Regression

- `git log` between provider tags showed commit `16829d7694` (duplicate hostname check) is the **only** change to `celery_command.py` between 3.13.1 and 3.14.0
- GitHub issue comments confirmed: downgrading to 3.13.1 fixes it
- The check is guarded by `if args.celery_hostname:` — explains why it only triggers with `--celery-hostname`

### Phase 3: State Dump — `_producer_pool` Tainting

Added debug logging at 4 checkpoints in `celery_command.py`:

```
BEFORE inspect(): app.amqp._producer_pool = None          ← clean
AFTER inspect():  app.amqp._producer_pool = <ProducerPool> ← tainted!
BEFORE worker_main(): app.amqp._producer_pool = <ProducerPool> ← still tainted
```

### Phase 4: `kombu.pools` Discovery

`dev/compare_constructors.py` revealed that `kombu.pools` is a **process-global** registry keyed by broker URL:

```python
app_a = Celery("a", broker="redis://localhost:6379/0")
app_b = Celery("b", config_source={"broker_url": "redis://localhost:6379/0"})

app_a.pool is app_b.pool  # True — same object!
app_a.amqp.producer_pool is app_b.amqp.producer_pool  # True — same object!
```

This invalidated the "use a temp app" fix — a temp app's `inspect()` still pollutes the global pool.

### Phase 5: Fork FD Tracing — Definitive Proof

`dev/fork_fd_tracer.py` used `os.register_at_fork()` to dump socket file descriptors in parent and child processes:

- **With `inspect()`**: Parent has 4 socket FDs, child inherits all 4 — **shared sockets proven**
- **Without `inspect()`**: Zero socket FDs in both parent and child
- **With `inspect()` + `kombu.pools.reset()`**: Sockets opened then closed, zero at fork time

### Phase 6: Fix Verification on EC2

Applied fix, reinstalled provider, ran same test:
- Task with `--celery-hostname "myworker@%h"` completed in 2.6 seconds
- DB confirmed: `say_hello | success`

---

## 5. Root Cause Analysis

### The Regression Commit

**Commit `16829d7694`** — "Add duplicate hostname check for Celery workers (#58591)"

Added this code to `celery_command.py` (lines 222-233):

```python
if args.celery_hostname:
    inspect = celery_app.control.inspect()
    active_workers = inspect.active_queues()
    if active_workers:
        active_worker_names = list(active_workers.keys())
        if any(name.endswith(f"@{args.celery_hostname}") for name in active_worker_names):
            raise SystemExit("Error: A worker with hostname '...' is already running.")
```

### What `inspect()` Does Internally

1. `celery_app.control.inspect()` creates an `Inspect` object
2. `.active_queues()` calls `control.broadcast()` which needs a producer
3. The producer comes from `app.amqp.producer_pool` (lazily created property)
4. `producer_pool` registers in `kombu.pools.producers` — a **process-global** dict
5. The producer opens a TCP connection to Redis (broker) to send the broadcast
6. The connection registers in `kombu.pools.connections` — also process-global

After `inspect()` returns:
- `app.amqp._producer_pool` is no longer `None`
- `kombu.pools` has 1 connection pool entry + 1 producer pool entry
- 4 TCP sockets are open to Redis

### What `worker_main()` Does

`worker_main()` starts the Celery worker, which with the `prefork` pool:

1. Calls `fork()` to create child worker processes
2. `fork()` duplicates the parent's entire memory space
3. This includes **file descriptor table** — children get copies of parent's FDs
4. Parent FD 8 (Redis socket) and child FD 8 (same socket) point to the **same kernel socket object**

### Why Shared Sockets Break Task Dispatch

With `-O fair` scheduling:

```
Consumer (parent)                Pool Worker (child)
     |                                  |
     | 1. Receive task from broker      |
     | 2. Put in RESERVED buffer        |
     | 3. Ask pool worker "ready?"  ────┤  (via pidbox/Redis)
     |    (uses shared socket FD 8)     |
     |                                  | 4. Reply "yes"
     |                                  |    (uses shared socket FD 8)
     | 5. Both processes R/W on same socket → CORRUPTION
     |    Messages interleave, protocol framing breaks
     |    Consumer never gets the "ready" reply
     | 6. Task stays in RESERVED forever
```

The pidbox mechanism uses Redis pub/sub for internal IPC. When parent and child share the same Redis connection, their pub/sub messages get interleaved. The consumer's "are you ready?" message and the child's "yes" response get corrupted or lost.

### Why It Only Happens With `--celery-hostname`

The `inspect()` call is guarded by `if args.celery_hostname:`. Without `--celery-hostname`:
- No `inspect()` call
- `_producer_pool` stays `None`
- `kombu.pools` stays empty
- `worker_main()` creates everything fresh after fork
- Each process gets its own Redis connections

### Why `kombu.pools` Makes "Temp App" Insufficient

`kombu.pools` is keyed by broker URL, not by app identity:

```python
kombu.pools.connections[('redis', 'localhost', None, None, '0', 6379, ...)] = <ConnectionPool>
```

Any Celery app connecting to `redis://localhost:6379/0` shares the same pool. Creating a "temp app" for `inspect()` still opens connections under the same key. The only way to clean up is `kombu.pools.reset()`.

---

## 6. Fork FD Tracing — Definitive Proof

### Script: `dev/fork_fd_tracer.py`

Uses `os.register_at_fork()` to capture socket file descriptors at fork boundaries:

```python
os.register_at_fork(
    before=lambda: log("PARENT BEFORE FORK: fds=%s", get_socket_fds()),
    after_in_child=lambda: log("CHILD AFTER FORK: fds=%s", get_socket_fds()),
)
```

### Test A: WITH `inspect()` + hostname (BUG PATH)

```
[STATE] INITIAL: socket FDs = {}
[INSPECT] Calling app.control.inspect().active_queues()...
[STATE] AFTER INSPECT: socket FDs = {5: 'socket:[758225]', 6: 'socket:[758229]',
                                      8: 'socket:[758233]', 9: 'socket:[758237]'}

[FORK] PARENT (pid=107541) BEFORE FORK: 4 socket FDs:
         {5: 'socket:[758225]', 6: 'socket:[758229]',
          8: 'socket:[758233]', 9: 'socket:[758237]'}

[FORK] CHILD (pid=107546, ppid=107541) AFTER FORK: 4 socket FDs:
         {5: 'socket:[758225]', 6: 'socket:[758229]',
          8: 'socket:[758233]', 9: 'socket:[758237]'}

[FORK] CHILD inherited 4 parent FDs: [5, 6, 8, 9]
[FORK] *** SHARED SOCKET FDs DETECTED ***
[FORK]   FD 5: parent=socket:[758225] child=socket:[758225]  ← SAME inode!
[FORK]   FD 6: parent=socket:[758229] child=socket:[758229]  ← SAME inode!
[FORK]   FD 8: parent=socket:[758233] child=socket:[758233]  ← SAME inode!
[FORK]   FD 9: parent=socket:[758237] child=socket:[758237]  ← SAME inode!
```

**Result:** 4 socket FDs shared between parent and child. Same inode numbers prove they're the same kernel socket objects.

### Test B: WITHOUT `inspect()` + hostname (CLEAN PATH)

```
[STATE] INITIAL: socket FDs = {}
[INSPECT] SKIPPING inspect()

[FORK] PARENT (pid=107685) BEFORE FORK: 0 socket FDs: {}
[FORK] CHILD (pid=107688, ppid=107685) AFTER FORK: 0 socket FDs: {}
[FORK] CHILD inherited 0 parent FDs: []
```

**Result:** Zero shared sockets. Clean state.

### Test C: WITH `inspect()` + `kombu.pools.reset()` + hostname (FIX PATH)

```
[STATE] INITIAL: socket FDs = {}
[INSPECT] Calling app.control.inspect().active_queues()...
[STATE] AFTER INSPECT: socket FDs = {5: 'socket:[762152]', 6: 'socket:[763068]',
                                      8: 'socket:[763072]', 9: 'socket:[763073]'}
[RESET] Calling kombu.pools.reset() + app.amqp._producer_pool = None...
[STATE] AFTER RESET: socket FDs = {}   ← ALL SOCKETS CLOSED

[FORK] PARENT (pid=107880) BEFORE FORK: 0 socket FDs: {}
[FORK] CHILD (pid=107882, ppid=107880) AFTER FORK: 0 socket FDs: {}
[FORK] CHILD inherited 0 parent FDs: []
```

**Result:** `kombu.pools.reset()` closes all sockets. Clean state at fork time, identical to Test B.

**Important finding from Test C:** `kombu.pools.reset()` alone (without `app.amqp._producer_pool = None`) causes `RuntimeError: Acquire on closed pool` because `worker_main()` tries to reuse the stale `_producer_pool` reference. Both resets are needed.

---

## 7. The Fix

### Code Change

**File:** `providers/celery/src/airflow/providers/celery/cli/celery_command.py`

```python
# BEFORE (broken):
if args.celery_hostname:
    inspect = celery_app.control.inspect()
    active_workers = inspect.active_queues()
    if active_workers:
        active_worker_names = list(active_workers.keys())
        if any(name.endswith(f"@{args.celery_hostname}") for name in active_worker_names):
            raise SystemExit(...)

# AFTER (fixed):
if args.celery_hostname:
    from celery import Celery as _TempCelery

    temp_app = _TempCelery(broker=celery_app.conf.broker_url)
    try:
        active_workers = temp_app.control.inspect().active_queues()
        if active_workers:
            celery_hostname = args.celery_hostname
            if any(
                name == celery_hostname or name.endswith(f"@{celery_hostname}")
                for name in active_workers
            ):
                raise SystemExit(
                    f"Error: A worker with hostname '{celery_hostname}' is already running. "
                    "Please use a different hostname or stop the existing worker first."
                )
    finally:
        temp_app.close()
        import kombu.pools
        kombu.pools.reset()
```

### What Each Part Does

1. **`_TempCelery(broker=...)`** — Creates a throwaway app that won't taint `celery_app`'s internal state
2. **`temp_app.close()`** — Closes the temp app's connections
3. **`kombu.pools.reset()`** — CRITICAL: clears the global `kombu.pools` registry, closing all sockets. Without this, the temp app's connections would persist in the global pool (keyed by broker URL) and get inherited by forked children.
4. **`name == celery_hostname or name.endswith(...)`** — Fixed duplicate detection to handle hostnames containing `@` (e.g., `"myworker@mymachine"` was not detected as duplicate because `endswith("@myworker@mymachine")` never matches)

### Why Both `temp_app.close()` AND `kombu.pools.reset()` Are Needed

- `temp_app.close()` closes the temp app's connections but does NOT clear `kombu.pools`
- `kombu.pools.reset()` clears the global registry AND closes the underlying socket connections
- Without `kombu.pools.reset()`, the sockets would persist and get inherited by forked children

---

## 8. EC2 Live Test Logs

### Test 1: Baseline — Worker WITHOUT `--celery-hostname` (PASSED)

```
celery@ip-10-0-2-61.us-west-2.compute.internal ready.

Task execute_workload[36941a4e-77b1-4494-b3f7-628d3c95fd72] received
[36941a4e...] Executing workload in Celery: ...task_id='say_hello'...
Secrets backends loaded for worker
Task finished  exit_code=0  final_state=success
Task execute_workload[36941a4e...] succeeded in 8.149s

DB: test_celery_hostname | say_hello | success
```

### Test 2: Bug Reproduction — Worker WITH `--celery-hostname` (STUCK)

```
myworker@ip-10-0-2-61.us-west-2.compute.internal ready.

Task execute_workload[5c97cd55-b026-4dbe-9805-faa7de4c7e4c] received
<< NO FURTHER OUTPUT — TASK NEVER DISPATCHED TO POOL >>

celery inspect reserved:
  myworker@ip-10-0-2-61...: OK
    * {
        'id': '5c97cd55-...',
        'name': 'execute_workload',
        'time_start': None,
        'acknowledged': False,
        'worker_pid': None
      }

DB: test_celery_hostname | say_hello | queued  (never progressed)
```

### Test 3: Fix Verified — Worker WITH `--celery-hostname` + Fix (PASSED)

```
[DEBUG-59707] CRITICAL: app.amqp._producer_pool is None (GOOD) at worker_main() time.

myworker@ip-10-0-2-61.us-west-2.compute.internal ready.

Task execute_workload[b41f1956-047b-4ac7-a7bc-a289cc311e39] received
[b41f1956...] Executing workload in Celery: ...task_id='say_hello'...
Secrets backends loaded for worker
Found credentials from IAM Role: AirflowInfra-celery-Ec2Role2FD9A272-EiqCNmCgJtwZ
Task finished  exit_code=0  final_state=success
Task execute_workload[b41f1956...] succeeded in 2.596s

DB: say_hello | success
```

### Summary Table

| Test | `--celery-hostname` | Fix Applied | `_producer_pool` at Fork | Socket FDs at Fork | Task Result |
|------|---------------------|-------------|--------------------------|--------------------| ------------|
| Baseline | No | N/A | `None` | 0 | **success** (8s) |
| Bug repro | `"myworker@%h"` | No | `<ProducerPool>` | 4 shared | **stuck RESERVED** |
| Fix verified | `"myworker@%h"` | Yes | `None` | 0 | **success** (2.6s) |

---

## 9. Theories Explored & Discarded

### Theory 1: `int` vs `str` for `--concurrency`

**Hypothesis:** `args.concurrency` is passed as `int` to `worker_main()` which expects strings.

**Investigation:** Changed `args.concurrency` to `str(args.concurrency)`. Worker banner still showed correct `concurrency: 1 (prefork)`. Tasks still stuck.

**Verdict:** Not the cause. Celery's Click-based argument parser handles int-to-str coercion.

### Theory 2: Celery library bug with `worker_main()` + `--hostname`

**Hypothesis:** `worker_main()` doesn't properly handle `--hostname`.

**Investigation:** Created standalone Celery script (`dev/test_celery_hostname_standalone.py`) with identical config. Worked fine.

**Verdict:** Not a Celery library bug. Airflow-specific.

### Theory 3: `-O fair` + `--hostname` interaction

**Hypothesis:** The fair scheduling strategy breaks when worker identity changes.

**Investigation:** The `-O fair` flag is fine — the issue is what happens BEFORE `worker_main()`.

**Verdict:** `-O fair` is necessary for the bug to manifest (it requires IPC), but it's not the cause.

### Theory 4: `config_source=` constructor is special

**Hypothesis:** `Celery(name, config_source=config)` creates apps differently from `Celery(broker=...)`.

**Investigation:** `dev/compare_constructors.py` showed both patterns produce identical internal state. Both register in the same `kombu.pools` global entries.

**Verdict:** Construction method doesn't matter. The issue is `kombu.pools` being global.

### Theory 5: Temp app approach would fix it

**Hypothesis:** Using a separate Celery app for `inspect()` would avoid tainting the main app.

**Investigation:** `compare_constructors.py` proved:
```
app_a.pool is app_b.pool: True
app_a.amqp.producer_pool is app_b.amqp.producer_pool: True
```

**Verdict:** Temp app alone is insufficient. Need `kombu.pools.reset()` to clear global state.

### Theory 6: Reset `_producer_pool = None` alone would fix it

**Hypothesis:** Just nullifying the producer pool reference is enough.

**Investigation:** `kombu.pools` still holds the open sockets. Worker would inherit them at fork.

**Verdict:** Need `kombu.pools.reset()` to close the actual sockets.

### Theory 7: `kombu.pools.reset()` alone would fix it

**Hypothesis:** Clearing global pools is enough.

**Investigation:** Fork FD tracer Test C showed `worker_main()` crashes with `RuntimeError: Acquire on closed pool` because `app.amqp._producer_pool` still references the now-invalidated pool.

**Verdict:** Need BOTH `kombu.pools.reset()` (close sockets) AND `app.amqp._producer_pool = None` (discard stale reference). The actual fix uses `temp_app.close()` + `kombu.pools.reset()` which handles both.

---

## 10. Infrastructure & Tooling

### Multi-Stack CDK Support

Added `suffix` parameter to the `airflow-ec2` CDK project so we could deploy a second stack alongside the existing one:

```bash
make deploy SUFFIX=celery       # Deploys AirflowInfra-celery + AirflowEc2-celery
make ssh SUFFIX=celery          # SSM into the celery stack's EC2
make destroy SUFFIX=celery      # Tear it down
```

All resource names are namespaced:
- SSM paths: `/airflow-test-celery/*` instead of `/airflow-test/*`
- S3 buckets: `airflow-ecs-logs-celery-*`, `airflow-ecs-dags-celery-*`
- ECR: `airflow-ecs-worker-celery`
- Stack names: `AirflowInfra-celery`, `AirflowEc2-celery`

### Remote Command Execution

All EC2 commands were executed via `aws ssm send-command` from the local Mac. Pattern:

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids i-06b68c955cf91ca55 \
  --document-name AWS-RunShellScript \
  --timeout-seconds 120 \
  --parameters '{"commands":["..."]}' \
  --output text --query 'Command.CommandId')

# Poll for completion
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "..."
```

For complex multi-line commands, we wrote to a temp script first to avoid shell quoting issues.

### Diagnostic Scripts Created

| Script | Purpose |
|--------|---------|
| `dev/fork_fd_tracer.py` | Traces socket FD inheritance across fork() boundaries |
| `dev/compare_constructors.py` | Compares Celery app state between `broker=` and `config_source=` constructors |
| `dev/test_celery_hostname_standalone.py` | Standalone Celery test to isolate Airflow vs Celery bugs |
| `dev/deep_diagnostic.py` | Comprehensive diagnostic with fork hooks, signals, kombu pool tracing |

---

## 11. Issues Encountered & Workarounds

| # | Issue | Impact | Workaround |
|---|-------|--------|------------|
| 1 | **Shell quoting in SSM send-command** | Commands with nested `${}` fail | Write to temp script file, then execute |
| 2 | **Services die when SSM exits** | `nohup` processes killed | Use `systemd-run --user --remain-after-exit` |
| 3 | **`airflow` not on PATH in SSM** | Commands fail | Always `source /opt/airflow-scripts/env.sh` first |
| 4 | **No multi-stack support** | Can't deploy second EC2 | Added `suffix` CDK parameter |
| 5 | **Branch only on fork** | `setup-airflow.sh` clones from `apache/airflow` | Pre-clone from fork before running setup |
| 6 | **Stale debug references** | Installed package has `_debug_celery_app_state` calls, function removed | `sed -i` to remove references from installed file |
| 7 | **`kombu.pools` iteration** | `Connections` object doesn't have `_data` attribute | Use standard `.items()` method |
| 8 | **Multiple workers from previous tests** | Old workers still running, confusing results | `pkill -9 -f celery` + `redis-cli FLUSHALL` before each test |

---

## 12. Reproduction Guide

### Quick Reproduction (Breeze)

```bash
# Start Breeze with Celery executor
breeze --backend postgres --executor CeleryExecutor

# Inside Breeze — worker WITHOUT hostname (works)
airflow celery worker --queues default --concurrency 1
# Trigger: airflow dags trigger example_bash_operator → completes

# Worker WITH hostname (broken)
airflow celery worker --queues default --concurrency 1 --celery-hostname "test@%h"
# Trigger: airflow dags trigger example_bash_operator → stuck in queued
```

### Full Reproduction on EC2

```bash
# 1. Deploy EC2 stack
cd ~/workspace/airflow-ec2
make deploy SUFFIX=celery

# 2. SSH in
make ssh SUFFIX=celery

# 3. Clone from fork + checkout branch
git clone https://github.com/shivaam/airflow.git ~/airflow
cd ~/airflow && git checkout investigate/celery-hostname-59707

# 4. Run setup
bash /opt/airflow-scripts/setup-airflow.sh

# 5. Install Redis + Celery
sudo dnf install -y redis6 && sudo systemctl enable --now redis6
source /opt/airflow-scripts/env.sh
uv pip install ./providers/celery "celery[redis]"

# 6. Configure CeleryExecutor in airflow.cfg
# executor=CeleryExecutor, broker_url=redis://localhost:6379/0

# 7. Restart services + deploy test DAG

# 8. Start worker WITH hostname → tasks stuck
airflow celery worker --queues default --concurrency 1 --celery-hostname "myworker@%h"

# 9. Inspect after 60s
celery -A airflow.providers.celery.executors.celery_executor_utils.app inspect reserved
# Shows task with acknowledged=False, worker_pid=None
```

### Fork FD Tracing

```bash
# On EC2, proves shared sockets:
python3 dev/fork_fd_tracer.py --inspect --hostname "tracer@%h"
# Shows: CHILD inherited 4 parent FDs, *** SHARED SOCKET FDs DETECTED ***

# Clean path (no shared sockets):
python3 dev/fork_fd_tracer.py --hostname "tracer@%h"
# Shows: CHILD inherited 0 parent FDs

# Fix path (sockets cleaned before fork):
python3 dev/fork_fd_tracer.py --inspect --reset --hostname "tracer@%h"
# Shows: AFTER RESET socket FDs = {}, CHILD inherited 0 parent FDs
```

---

## 13. Files & Artifacts

### Airflow Repo (`shivaam/airflow`, branch `investigate/celery-hostname-59707`)

| File | Purpose |
|------|---------|
| `providers/celery/src/.../cli/celery_command.py` | The fix (temp app + kombu.pools.reset) |
| `.claude/celery-hostname-issue-59707/investigation.md` | Root cause analysis + code walkthrough |
| `.claude/celery-hostname-issue-59707/test-plan.md` | Test matrix + updated root cause |
| `.claude/celery-hostname-issue-59707/proposed-fix.md` | Fix proposals |
| `.claude/celery-hostname-issue-59707/breeze-testing-guide.md` | How to test with Breeze |
| `dev/fork_fd_tracer.py` | Fork FD inheritance tracer |
| `dev/compare_constructors.py` | kombu.pools global state comparison |
| `dev/test_celery_hostname_standalone.py` | Standalone Celery test |
| `dev/deep_diagnostic.py` | Comprehensive diagnostic script |

### airflow-ec2 Repo (`shivaam/airflow-ec2`, branch `investigate/celery-hostname-59707`)

| File | Purpose |
|------|---------|
| `cdk/lib/*.ts` | Multi-stack suffix support |
| `ec2-scripts/env.sh` | Dynamic SSM prefix |
| `ec2-scripts/airflow-cli-helpers.sh` | Dynamic SSM prefix in CLI helpers |
| `Makefile` | SUFFIX variable for all targets |
| `.claude/issues-and-improvements.md` | Issues hit + improvements |
| `docs/celery-hostname-investigation/` | All investigation docs (mirror) |
