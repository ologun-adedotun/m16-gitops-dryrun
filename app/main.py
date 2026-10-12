import json
import logging
import os
import random
import sys
import time

from fastapi import FastAPI, Query, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest

# Settings come from environment variables, with a safe default for each.
APP_NAME = os.environ.get("APP_NAME", "maright-app")
GREETING = os.environ.get("GREETING", "Hello from Mission Control")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
READY_AFTER_SECONDS = float(os.environ.get("READY_AFTER_SECONDS", "5"))


class JsonFormatter(logging.Formatter):
    """Write every log line as one line of JSON, so a computer can read it."""

    def format(self, record):
        return json.dumps({
            "time": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "app": APP_NAME,
            "message": record.getMessage(),
        })


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger(APP_NAME)
log.addHandler(handler)
log.setLevel(LOG_LEVEL)
log.propagate = False

REQUESTS = Counter("app_requests_total", "Requests answered, by path", ["path"])
STARTED = time.time()

app = FastAPI(title=APP_NAME)
log.info("starting up")


@app.get("/")
def home():
    REQUESTS.labels(path="/").inc()
    log.info("home page served")
    return {"app": APP_NAME, "message": GREETING}


@app.get("/health")
def health():
    REQUESTS.labels(path="/health").inc()
    return {"status": "ok"}


@app.get("/ready")
def ready(response: Response):
    REQUESTS.labels(path="/ready").inc()
    if time.time() - STARTED < READY_AFTER_SECONDS:
        response.status_code = 503
        return {"status": "starting"}
    return {"status": "ready"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/work")
def work(
    response: Response,
    ms: int = Query(0, ge=0, le=30000),
    cpu_ms: int = Query(0, ge=0, le=2000),
    fail: float = Query(0.0, ge=0.0, le=1.0),
):
    """Simulated work: wait ms, burn cpu_ms of CPU, then fail a share of requests."""
    REQUESTS.labels(path="/work").inc()
    if cpu_ms:
        end = time.perf_counter() + cpu_ms / 1000
        while time.perf_counter() < end:
            pass
    if ms:
        time.sleep(ms / 1000)
    if fail and random.random() < fail:
        response.status_code = 503
        return {"status": "failed"}
    return {"status": "done"}
