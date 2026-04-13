#!/bin/bash
# Generate airflow.cfg for a given executor type.
# Usage: bash gen-airflow-cfg.sh <local|ecs>
# Writes to ${AIRFLOW_HOME}/airflow.cfg
set -e

EXECUTOR_TYPE="${1:?Usage: gen-airflow-cfg.sh <local|ecs>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

JWT_SECRET=$(python3 -c "import secrets, base64; print(base64.urlsafe_b64encode(secrets.token_bytes(64)).decode())")

# Preserve existing JWT secret if config exists
if [ -f "${AIRFLOW_HOME}/airflow.cfg" ]; then
    EXISTING_JWT=$(grep -oP 'jwt_secret\s*=\s*\K.*' "${AIRFLOW_HOME}/airflow.cfg" 2>/dev/null || true)
    if [ -n "$EXISTING_JWT" ]; then
        JWT_SECRET="$EXISTING_JWT"
    fi
fi

mkdir -p "${AIRFLOW_HOME}"

# Common sections
cat > "${AIRFLOW_HOME}/airflow.cfg" << EOF
[database]
sql_alchemy_conn = postgresql+psycopg2://${DB_USER}:${DB_PASS}@${DB_ENDPOINT}:5432/${DB_NAME}

[api]
expose_config = True

[api_auth]
jwt_secret = ${JWT_SECRET}

[logging]
remote_logging = True
remote_base_log_folder = s3://${LOG_BUCKET}/logs
remote_log_conn_id = aws_default
EOF

case "${EXECUTOR_TYPE}" in
    local)
        cat >> "${AIRFLOW_HOME}/airflow.cfg" << EOF

[core]
executor = LocalExecutor
execution_api_server_url = http://localhost:8080/execution/
auth_manager = airflow.api_fastapi.auth.managers.simple.simple_auth_manager.SimpleAuthManager
simple_auth_manager_all_admins = true

[dag_processor]
dag_bundle_config_list = [{"name": "dags", "classpath": "airflow.providers.amazon.aws.bundles.s3.S3DagBundle", "kwargs": {"bucket_name": "${DAG_BUCKET}", "prefix": "dags"}}]
EOF
        ;;

    ecs)
        if [ -z "${NLB_DNS}" ] || [ "${NLB_DNS}" = "None" ]; then
            echo "ERROR: NLB not deployed. Run 'make deploy-ecs' first to create ECS stacks."
            exit 1
        fi
        cat >> "${AIRFLOW_HOME}/airflow.cfg" << EOF

[core]
executor = LocalExecutor;team_alpha=airflow.providers.amazon.aws.executors.ecs.ecs_executor.AwsEcsExecutor;team_beta=airflow.providers.amazon.aws.executors.ecs.ecs_executor.AwsEcsExecutor
multi_team = True
execution_api_server_url = http://${NLB_DNS}:8080/execution/
auth_manager = airflow.api_fastapi.auth.managers.simple.simple_auth_manager.SimpleAuthManager
simple_auth_manager_all_admins = true

[dag_processor]
dag_bundle_config_list = [{"name": "team_alpha_dags", "classpath": "airflow.providers.amazon.aws.bundles.s3.S3DagBundle", "kwargs": {"bucket_name": "${DAG_BUCKET}", "prefix": "team_alpha"}, "team_name": "team_alpha"}, {"name": "team_beta_dags", "classpath": "airflow.providers.amazon.aws.bundles.s3.S3DagBundle", "kwargs": {"bucket_name": "${DAG_BUCKET}", "prefix": "team_beta"}, "team_name": "team_beta"}, {"name": "shared_dags", "classpath": "airflow.providers.amazon.aws.bundles.s3.S3DagBundle", "kwargs": {"bucket_name": "${DAG_BUCKET}", "prefix": "shared"}}]

[team_alpha=aws_ecs_executor]
cluster = alpha-cluster
container_name = airflow-worker
task_definition = ${ALPHA_TASK_DEF}
subnets = ${PRIVATE_SUBNETS}
security_groups = ${WORKER_SG}
launch_type = FARGATE
assign_public_ip = False
region_name = ${REGION}

[team_beta=aws_ecs_executor]
cluster = beta-cluster
container_name = airflow-worker
task_definition = ${BETA_TASK_DEF}
subnets = ${PRIVATE_SUBNETS}
security_groups = ${WORKER_SG}
launch_type = FARGATE
assign_public_ip = False
region_name = ${REGION}
EOF
        ;;

    *)
        echo "Unknown executor type: ${EXECUTOR_TYPE}"
        echo "Supported: local, ecs"
        exit 1
        ;;
esac

echo "Written ${AIRFLOW_HOME}/airflow.cfg (executor: ${EXECUTOR_TYPE})"
