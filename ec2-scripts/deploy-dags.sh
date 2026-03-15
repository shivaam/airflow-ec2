#!/bin/bash
# Create test DAGs and upload to S3.
# Usage: bash /opt/airflow-scripts/deploy-dags.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

log_step "Creating test DAGs"
mkdir -p "${DAG_STAGING_DIR}/dags"

cat > "${DAG_STAGING_DIR}/dags/hello_world.py" << 'PYEOF'
"""Hello world DAG — verifies Airflow is working."""
from __future__ import annotations
from datetime import datetime
from airflow.sdk import dag, task

@dag(schedule=None, start_date=datetime(2026, 1, 1), catchup=False, tags=["example"])
def hello_world():
    @task
    def say_hello():
        import socket
        print(f"Hello from Airflow on {socket.gethostname()}")
        return "done"
    say_hello()

hello_world()
PYEOF

log_step "Uploading to S3"
aws s3 sync "${DAG_STAGING_DIR}/" "s3://${DAG_BUCKET}/" --delete
log_info "DAGs uploaded to s3://${DAG_BUCKET}/"
log_info "Dag-processor will pick them up on next refresh cycle."
