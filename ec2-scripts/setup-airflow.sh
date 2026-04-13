#!/bin/bash
# One-shot Airflow setup on EC2. Run once after CDK deploy + first SSM login.
#
# What this does:
#   1. Clone airflow repo from GitHub
#   2. Install dev tooling (pnpm, docker-compose v2, breeze)
#   3. Create Python venv + install Airflow, task-sdk, amazon provider
#   4. Build all UI assets (main UI + simple auth manager UI)
#   5. Write airflow.cfg (LocalExecutor, S3 DAG bundle)
#   6. Initialize DB
#   7. Create test DAGs + upload to S3
#   8. Start all services
#
# Usage: sudo su - ec2-user && bash /opt/airflow-scripts/setup-airflow.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "============================================"
echo "  Airflow Setup"
echo "============================================"

# ── 1. Clone repo ─────────────────────────────────────────────────────
log_step "1/8 Cloning airflow repo"
log_info "Repo: ${AIRFLOW_REPO}"
log_info "Branch: ${AIRFLOW_BRANCH}"
if [ ! -d "${AIRFLOW_SRC}/.git" ]; then
    git clone --branch "${AIRFLOW_BRANCH}" "${AIRFLOW_REPO}" "${AIRFLOW_SRC}"
else
    log_info "Repo exists, fetching and checking out ${AIRFLOW_BRANCH}..."
    cd "${AIRFLOW_SRC}"
    git fetch --all
    git checkout "${AIRFLOW_BRANCH}"
    git pull origin "${AIRFLOW_BRANCH}" 2>/dev/null || true
fi

# ── 2. Install dev tooling ────────────────────────────────────────────
log_step "2/8 Installing dev tooling (pnpm, docker-compose v2, breeze)"

# pnpm (needed for simple auth manager UI build)
if ! command -v pnpm &>/dev/null; then
    log_info "Installing pnpm..."
    sudo npm install -g pnpm
fi

# docker-compose v2 (needed for breeze)
if ! docker compose version &>/dev/null; then
    log_info "Installing docker-compose v2 plugin..."
    sudo mkdir -p /usr/local/lib/docker/cli-plugins
    sudo curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose
    sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

# breeze (from local source for version match)
if ! command -v breeze &>/dev/null; then
    log_info "Installing breeze from source..."
    uv tool install -e "${AIRFLOW_SRC}/dev/breeze"
fi

# ── 3. Python venv + install ──────────────────────────────────────────
log_step "3/8 Installing Airflow"
cd "${AIRFLOW_SRC}"
uv venv "${AIRFLOW_VENV}" --python 3.12 2>/dev/null || true
source "${AIRFLOW_VENV}/bin/activate"
uv pip install ./airflow-core ./task-sdk ./providers/amazon asyncpg psycopg2-binary

# ── 4. Build all UI assets ────────────────────────────────────────────
log_step "4/8 Building UI assets"

# Main Airflow UI
cd "${AIRFLOW_UI_DIR}"
npm install --legacy-peer-deps 2>&1 | tail -3
npm run build 2>&1 | tail -3

# Simple Auth Manager UI
SIMPLE_AUTH_UI="${AIRFLOW_SRC}/airflow-core/src/airflow/api_fastapi/auth/managers/simple/ui"
cd "${SIMPLE_AUTH_UI}"
pnpm install 2>&1 | tail -3
pnpm build 2>&1 | tail -3

cd "${AIRFLOW_SRC}"

# ── 4. Write airflow.cfg ──────────────────────────────────────────────
log_step "5/8 Writing airflow.cfg"
bash "${SCRIPT_DIR}/gen-airflow-cfg.sh" local

# ── 5. Init DB ────────────────────────────────────────────────────────
log_step "6/8 Initializing DB"
PGPASSWORD="${DB_PASS}" psql -h "${DB_ENDPOINT}" -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" > /dev/null
airflow db migrate 2>&1 | tail -5

# ── 6. Create test DAGs + upload to S3 ────────────────────────────────
log_step "7/8 Deploying test DAGs to S3"
bash "${SCRIPT_DIR}/deploy-dags.sh"

# ── 7. Start services ─────────────────────────────────────────────────
log_step "8/8 Starting Airflow services"
bash "${SCRIPT_DIR}/airflow-ctl.sh" start

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "Quick commands (available in any shell):"
echo "  af status     - check service health"
echo "  af restart    - restart all services"
echo "  af logs       - tail all logs"
echo "  af db         - psql into metadata DB"
echo ""
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
echo "UI access (from your Mac):"
echo "  aws ssm start-session --target ${INSTANCE_ID} \\"
echo "    --document-name AWS-StartPortForwardingSession \\"
echo "    --parameters '{\"portNumber\":[\"8080\"],\"localPortNumber\":[\"8080\"]}'"
echo ""
echo "Then open http://localhost:8080"
