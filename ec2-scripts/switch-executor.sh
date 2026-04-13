#!/bin/bash
# Switch executor mode without redeploying CDK. Regenerates airflow.cfg and restarts.
#
# Usage: bash /opt/airflow-scripts/switch-executor.sh <local|ecs>
set -e

EXECUTOR_TYPE="${1:?Usage: switch-executor.sh <local|ecs>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

log_step "Switching to executor: ${EXECUTOR_TYPE}"

log_info "Stopping services..."
bash "${SCRIPT_DIR}/airflow-ctl.sh" stop

log_info "Generating airflow.cfg for ${EXECUTOR_TYPE}..."
bash "${SCRIPT_DIR}/gen-airflow-cfg.sh" "${EXECUTOR_TYPE}"

if [ "${EXECUTOR_TYPE}" = "ecs" ]; then
    log_info "Creating teams (if they don't exist)..."
    bash "${SCRIPT_DIR}/airflow-ctl.sh" start
    sleep 5
    airflow teams create team_alpha 2>/dev/null || true
    airflow teams create team_beta 2>/dev/null || true
    log_info "ECS executor active. Make sure worker image is built: af rebuild"
else
    log_info "Starting services..."
    bash "${SCRIPT_DIR}/airflow-ctl.sh" start
fi

log_info "Switched to ${EXECUTOR_TYPE} executor."
