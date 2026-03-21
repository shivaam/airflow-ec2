# Issues Encountered & Workflow Improvements

## Issues Hit During Celery Hostname Investigation

| # | Issue | Impact | Root Cause | Workaround Used |
|---|-------|--------|------------|-----------------|
| 1 | **Shell quoting mangled in SSM send-command** | DB reset command failed (`psql: error: could not translate host name "-U"`) | Nested `${}` variable expansion inside double-quoted JSON `commands` parameter gets eaten by the outer shell before reaching EC2 | Write multi-line commands to a temp script file on EC2 first (heredoc to `/tmp/step-X.sh`), then execute the script |
| 2 | **Services die when SSM session exits** | `nohup` processes started via `send-command` are killed when the SSM command finishes | SSM `RunShellScript` runs in a transient shell session. `nohup` only prevents HUP signals but the process group is still terminated when the SSM agent cleans up | Use `systemd-run --user --unit=<name> --remain-after-exit` which creates a proper systemd scope that outlives the shell |
| 3 | **DB migration failed — airflow not on PATH** | `airflow db migrate` command not found in send-command context | The Python venv wasn't activated in the SSM command's shell context — env.sh wasn't sourced | Always `source /opt/airflow-scripts/env.sh` as the first line in any SSM command (it activates the venv) |
| 4 | **No multi-stack support in CDK** | Couldn't deploy a second EC2 for Celery testing without resource name collisions | All resource names and SSM parameter paths were hardcoded (`/airflow-test/*`, `airflow-ecs-logs-*`, etc.) | Added `suffix` CDK context parameter that namespaces all stack IDs, SSM paths, S3 bucket names, ECR repo names |
| 5 | **Investigation branch only on user's fork** | `setup-airflow.sh` clones from `apache/airflow` which doesn't have the investigation branch | The branch `investigate/celery-hostname-59707` lives on `shivaam/airflow`, not upstream | Clone from fork first, add `upstream` as separate remote. Setup detects existing repo and skips clone step |
| 6 | **`setup-airflow.sh` hardcodes GitHub URL** | Can't easily test branches on forks without manual intervention | `git clone https://github.com/apache/airflow.git` is hardcoded in setup | Pre-clone from the desired remote before running setup. Setup's "repo exists" path runs `git pull` which works on whatever remote the current branch tracks |

---

## Suggested Improvements for `airflow-ec2`

### High Priority

#### 1. Add `make run` target for remote command execution
Wrap `aws ssm send-command` with proper quoting, polling, stdout/stderr capture:

```makefile
run:
	@scripts/run-remote.sh "$(SUFFIX)" "$(CMD)"
# Usage: make run SUFFIX=celery CMD="af status"
```

The `run-remote.sh` helper should:
- Accept a command string
- Write it to a temp file on the instance
- Execute via SSM send-command
- Poll for completion with timeout
- Print stdout/stderr on completion
- Return the correct exit code

#### 2. Replace `nohup` with `systemd-run` in `airflow-ctl.sh`
Services started via SSM need to survive session exit:

```bash
# Before (dies with SSM session):
nohup airflow api-server --port 8080 > "${LOG_DIR}/api-server.log" 2>&1 &

# After (survives SSM session):
systemd-run --user --unit=af-apiserver --remain-after-exit \
  bash -c "airflow api-server --port 8080 > ${LOG_DIR}/api-server.log 2>&1"
```

Update `_stop()` to use `systemctl --user stop af-*` in addition to `pkill`.

#### 3. Parameterize git clone URL in `setup-airflow.sh`
Accept `AIRFLOW_REPO_URL` environment variable:

```bash
REPO_URL="${AIRFLOW_REPO_URL:-https://github.com/apache/airflow.git}"
if [ ! -d "${AIRFLOW_SRC}/.git" ]; then
    git clone "$REPO_URL" "${AIRFLOW_SRC}"
fi
```

This enables testing branches on forks without manual clone-before-setup.

### Medium Priority

#### 4. CDK: Output SSM prefix as CfnOutput
Add to `infra-stack.ts`:
```typescript
new cdk.CfnOutput(this, 'SsmPrefix', {
  value: ssmPrefix,
  description: 'SSM parameter prefix for this stack',
});
```

This lets the Makefile auto-detect the SSM prefix instead of computing it.

#### 5. Add SSM send-command timeout to env.sh
Export instance ID and default timeouts:
```bash
export INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
```

#### 6. Add `af celery` subcommand to cli-helpers
For Celery-specific workflows:
```bash
af celery worker [--hostname X]  # Start worker
af celery inspect                # Inspect reserved/active
af celery stop                   # Stop worker
```

### Low Priority

#### 7. Add health check endpoint polling to `_start()`
After starting services, poll `/health` endpoint instead of just `sleep 5`:
```bash
for i in $(seq 1 30); do
  curl -sf http://localhost:8080/health && break
  sleep 2
done
```

#### 8. Add `make logs SUFFIX=celery` target
Stream logs from EC2 via SSM session:
```makefile
logs:
	aws ssm start-session --target $(INSTANCE_ID) \
	  --document-name AWS-StartInteractiveCommand \
	  --parameters command='["tail -f /tmp/api-server.log /tmp/scheduler.log"]'
```
