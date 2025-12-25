#!/usr/bin/env bash

set -e

# -----------------------------------------------------------------------------
# Usage and command-line argument parsing
# -----------------------------------------------------------------------------
function usage() {
    echo "Usage: $0 [--disable-webserver] [--disable-taskexecutor] [--disable-datasync] [--consumer-no-beg=<num>] [--consumer-no-end=<num>] [--workers=<num>] [--host-id=<string>]"
    echo
    echo "  --disable-webserver             Disables the web server (nginx + ragflow_server)."
    echo "  --disable-taskexecutor          Disables task executor workers."
    echo "  --disable-datasync              Disables synchronization of datasource workers."
    echo "  --enable-mcpserver              Enables the MCP server."
    echo "  --enable-adminserver            Enables the Admin server."
    echo "  --init-superuser                Initializes the superuser."
    echo "  --consumer-no-beg=<num>         Start range for consumers (if using range-based)."
    echo "  --consumer-no-end=<num>         End range for consumers (if using range-based)."
    echo "  --workers=<num>                 Number of task executors to run (if range is not used)."
    echo "  --host-id=<string>              Unique ID for the host (defaults to \`hostname\`)."
    echo
    echo "Examples:"
    echo "  $0 --disable-taskexecutor"
    echo "  $0 --disable-webserver --consumer-no-beg=0 --consumer-no-end=5"
    echo "  $0 --disable-webserver --workers=2 --host-id=myhost123"
    echo "  $0 --enable-mcpserver"
    echo "  $0 --enable-adminserver"
    echo "  $0 --init-superuser"
    exit 1
}

ENABLE_WEBSERVER=1 # Default to enable web server
ENABLE_TASKEXECUTOR=1  # Default to enable task executor
ENABLE_DATASYNC=1
ENABLE_MCP_SERVER=0
ENABLE_ADMIN_SERVER=0 # Default close admin server
INIT_SUPERUSER_ARGS="" # Default to not initialize superuser
CONSUMER_NO_BEG=0
CONSUMER_NO_END=0
WORKERS=1

# -----------------------------------------------------------------------------
# Host ID logic:
#   1. By default, use the system hostname if length <= 32
#   2. Otherwise, use the full MD5 hash of the hostname (32 hex chars)
# -----------------------------------------------------------------------------
CURRENT_HOSTNAME="$(hostname)"
if [ ${#CURRENT_HOSTNAME} -le 32 ]; then
  DEFAULT_HOST_ID="$CURRENT_HOSTNAME"
else
  DEFAULT_HOST_ID="$(echo -n "$CURRENT_HOSTNAME" | md5sum | cut -d ' ' -f 1)"
fi

HOST_ID="$DEFAULT_HOST_ID"

# Parse arguments
for arg in "$@"; do
  case $arg in
    --disable-webserver)
      ENABLE_WEBSERVER=0
      shift
      ;;
    --disable-taskexecutor)
      ENABLE_TASKEXECUTOR=0
      shift
      ;;
    --disable-datasync)
      ENABLE_DATASYNC=0
      shift
      ;;
    --enable-mcpserver)
      ENABLE_MCP_SERVER=1
      shift
      ;;
    --enable-adminserver)
      ENABLE_ADMIN_SERVER=1
      shift
      ;;
    --init-superuser)
      INIT_SUPERUSER_ARGS="--init-superuser"
      shift
      ;;
    --no-transport-sse-enabled)
      MCP_TRANSPORT_SSE_FLAG="--no-transport-sse-enabled"
      shift
      ;;
    --no-transport-streamable-http-enabled)
      MCP_TRANSPORT_STREAMABLE_HTTP_FLAG="--no-transport-streamable-http-enabled"
      shift
      ;;
    --no-json-response)
      MCP_JSON_RESPONSE_FLAG="--no-json-response"
      shift
      ;;
    --consumer-no-beg=*)
      CONSUMER_NO_BEG="${arg#*=}"
      shift
      ;;
    --consumer-no-end=*)
      CONSUMER_NO_END="${arg#*=}"
      shift
      ;;
    --workers=*)
      WORKERS="${arg#*=}"
      shift
      ;;
    --host-id=*)
      HOST_ID="${arg#*=}"
      shift
      ;;
    *)
      usage
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Replace env variables in the service_conf.yaml file
# -----------------------------------------------------------------------------
CONF_DIR="/ragflow/conf"
TEMPLATE_FILE="${CONF_DIR}/service_conf.yaml.template"
CONF_FILE="${CONF_DIR}/service_conf.yaml"

rm -f "${CONF_FILE}"
while IFS= read -r line || [[ -n "$line" ]]; do
    eval "echo \"$line\"" >> "${CONF_FILE}"
done < "${TEMPLATE_FILE}"

export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu/"
PY=python3

# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------

get_jemalloc() {
    pkg-config --variable=libdir jemalloc 2>/dev/null | sed 's#$#/libjemalloc.so#'
}

ensure_docling() {
    [[ "${USE_DOCLING}" == "true" ]] || { echo "[docling] disabled"; return 0; }
    python3 -c 'import docling' >/dev/null 2>&1 && return 0
    python3 -m ensurepip --upgrade || true
    python3 -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple \
        --extra-index-url https://pypi.org/simple \
        --no-cache-dir "docling${DOCLING_VERSION:-==2.58.0}"
}

# -----------------------------------------------------------------------------
# Service starters
# -----------------------------------------------------------------------------

start_ragflow_server() {
    echo "[ragflow] starting ragflow server"

    exec uvicorn \
        api.asgi:app \
        --host 0.0.0.0 \
        --port ${SVR_HTTP_PORT:-9380} \
        --workers 1 \
        --log-level ${SVR_LOG_LEVEL:-info}
}

start_task_executor() {
    CONSUMER_ID="${CONSUMER_ID:-${HOST_ID}}"
    echo "[task-executor] starting worker, consumer_id=${CONSUMER_ID}"

    JEMALLOC_PATH="$(get_jemalloc)"
    if [[ -f "${JEMALLOC_PATH}" ]]; then
        echo "[task-executor] using jemalloc: ${JEMALLOC_PATH}"
        exec env LD_PRELOAD="${JEMALLOC_PATH}" \
            "$PY" rag/svr/task_executor.py "${CONSUMER_ID}"
    else
        echo "[task-executor] jemalloc not found, fallback to glibc"
        exec "$PY" rag/svr/task_executor.py "${CONSUMER_ID}"
    fi
}

start_admin_server() {
    echo "[admin] starting admin server"
    exec "$PY" admin/server/admin_server.py
}

start_datasync() {
    echo "[datasync] starting data sync worker"
    exec "$PY" rag/svr/sync_data_source.py
}


# -----------------------------------------------------------------------------
# Entrypoint
# -----------------------------------------------------------------------------

ensure_docling

case "$SERVICE" in
    ragflow)
        start_ragflow_server
        ;;
    task-executor)
        start_task_executor
        ;;
    admin)
        start_admin_server
        ;;
    datasync)
        start_datasync
        ;;
    *)
        echo "[entrypoint] Unknown SERVICE=$SERVICE"
        exit 1
        ;;
esac