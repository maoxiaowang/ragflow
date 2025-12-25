import argparse
import faulthandler
import logging
import signal
import sys
import threading
import uuid

from api.apps import app
from api.db.db_models import init_database_tables as init_web_db
from api.db.init_data import init_web_data, init_superuser
from api.db.runtime_config import RuntimeConfig
from api.db.services.document_service import DocumentService
from common import settings
from common.config_utils import show_configs
from common.log_utils import init_root_logger
from common.mcp_tool_call_conn import shutdown_all_mcp_sessions
from common.versions import get_ragflow_version
from plugin import GlobalPluginManager
from rag.utils.redis_conn import RedisDistributedLock

# -------------------
# 初始化
# -------------------
faulthandler.enable()
init_root_logger("ragflow_server")
logging.info("RAGFlow ASGI app starting...")

settings.init_settings()
show_configs()
settings.print_rag_settings()

# -------------------
# 命令行参数解析
# -------------------
parser = argparse.ArgumentParser()
parser.add_argument("--version", action="store_true", help="Show RAGFlow version")
parser.add_argument("--debug", action="store_true", help="Debug mode")
parser.add_argument("--init-superuser", action="store_true", help="Init superuser")
args, unknown = parser.parse_known_args()

if args.version:
    print(get_ragflow_version())
    sys.exit(0)

# -------------------
# 数据库初始化
# -------------------
init_web_db()
init_web_data()
if args.init_superuser:
    init_superuser()

# -------------------
# RuntimeConfig & 插件
# -------------------
RuntimeConfig.DEBUG = args.debug
if RuntimeConfig.DEBUG:
    logging.info("Running in debug mode")

RuntimeConfig.init_env()
RuntimeConfig.init_config(JOB_SERVER_HOST=settings.HOST_IP, HTTP_PORT=settings.HOST_PORT)
GlobalPluginManager.load_plugins()

# -------------------
# update_progress 后台线程
# -------------------
stop_event = threading.Event()


def update_progress():
    lock_value = str(uuid.uuid4())
    redis_lock = RedisDistributedLock("update_progress", lock_value=lock_value, timeout=60)
    logging.info(f"update_progress lock_value: {lock_value}")
    while not stop_event.is_set():
        try:
            if redis_lock.acquire():
                DocumentService.update_progress()
                redis_lock.release()
        except Exception:
            logging.exception("update_progress exception")
        finally:
            try:
                redis_lock.release()
            except Exception:
                pass
            stop_event.wait(6)


def start_update_progress_thread():
    t = threading.Thread(target=update_progress, daemon=True)
    t.start()


start_update_progress_thread()


# -------------------
# 信号处理
# -------------------
def signal_handler(sig, frame):
    logging.info("Received interrupt signal, shutting down...")
    shutdown_all_mcp_sessions()
    stop_event.set()
    stop_event.wait(1)
    sys.exit(0)


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

# -------------------
# 最终暴露 ASGI app
# -------------------
# uvicorn / gunicorn 引用此 app 即可

__all__ = ["app"]
