"""
notes-app - a deliberately small web application used throughout the workshop.

It behaves like a typical application that was originally built to run with
`docker run` on a single VM:

* configuration comes from environment variables (with defaults baked in)
* notes are stored on local disk unless DATABASE_URL is set
* everything is logged to stdout

Endpoints:
  GET  /               HTML page (greeting, pod name, notes)
  POST /notes          add a note from the HTML form
  GET  /api/info       JSON: version, environment, pod, storage backend
  GET  /api/notes      JSON: list of notes
  POST /api/notes      JSON body {"text": "..."} adds a note
  GET  /healthz/live   liveness: the process is running
  GET  /healthz/ready  readiness: the storage backend is reachable
"""
import html
import logging
import os
import socket
import sys
from datetime import datetime, timezone

from flask import Flask, jsonify, redirect, request

logging.basicConfig(
    stream=sys.stdout,
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s notes-app %(message)s",
)
log = logging.getLogger("notes-app")

APP_VERSION = os.getenv("APP_VERSION", "dev")
APP_GREETING = os.getenv("APP_GREETING", "Hello")
APP_ENV = os.getenv("APP_ENV", "unknown")
API_TOKEN = os.getenv("API_TOKEN", "")
DATA_DIR = os.getenv("DATA_DIR", "/data")
DATABASE_URL = os.getenv("DATABASE_URL", "")
PORT = int(os.getenv("PORT", "8080"))
POD = socket.gethostname()


class FileStore:
    """Stores notes in a local file. Each replica has its own copy."""

    name = "local-file"

    def __init__(self, data_dir):
        self.path = os.path.join(data_dir, "notes.txt")
        os.makedirs(data_dir, exist_ok=True)
        # Fail fast, like many vendor apps do, if the directory is not writable.
        with open(self.path, "a", encoding="utf-8"):
            pass
        log.info("storage=local-file path=%s", self.path)

    def add(self, text):
        stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(f"{stamp}\t{POD}\t{text}\n")

    def list(self):
        notes = []
        with open(self.path, encoding="utf-8") as f:
            for line in f:
                stamp, pod, text = line.rstrip("\n").split("\t", 2)
                notes.append({"created": stamp, "pod": pod, "text": text})
        return notes

    def ping(self):
        return os.access(self.path, os.W_OK)


class PostgresStore:
    """Stores notes in PostgreSQL. All replicas share the same data."""

    name = "postgresql"

    def __init__(self, url):
        import psycopg  # imported lazily so the file backend has no DB dependency

        self.psycopg = psycopg
        self.url = url
        with self._conn() as conn:
            # Several workers and pods start at the same time. CREATE TABLE IF
            # NOT EXISTS is not safe under concurrency in PostgreSQL, so take a
            # transaction-scoped advisory lock first (released on commit).
            conn.execute("SELECT pg_advisory_xact_lock(4242)")
            conn.execute(
                "CREATE TABLE IF NOT EXISTS notes ("
                " id SERIAL PRIMARY KEY,"
                " created TIMESTAMPTZ NOT NULL DEFAULT now(),"
                " pod TEXT NOT NULL,"
                " text TEXT NOT NULL)"
            )
        log.info("storage=postgresql")

    def _conn(self):
        return self.psycopg.connect(self.url, connect_timeout=3)

    def add(self, text):
        with self._conn() as conn:
            conn.execute("INSERT INTO notes (pod, text) VALUES (%s, %s)", (POD, text))

    def list(self):
        with self._conn() as conn:
            rows = conn.execute(
                "SELECT created, pod, text FROM notes ORDER BY id"
            ).fetchall()
        return [
            {"created": r[0].isoformat(timespec="seconds"), "pod": r[1], "text": r[2]}
            for r in rows
        ]

    def ping(self):
        try:
            with self._conn() as conn:
                conn.execute("SELECT 1")
            return True
        except Exception as exc:  # noqa: BLE001
            log.warning("readiness check failed: %s", exc)
            return False


store = PostgresStore(DATABASE_URL) if DATABASE_URL else FileStore(DATA_DIR)
app = Flask(__name__)


def token_status():
    if not API_TOKEN:
        return "not configured"
    return f"configured (ends with ...{API_TOKEN[-4:]})"


@app.get("/")
def index():
    items = "".join(
        f"<li><code>{html.escape(n['created'])}</code> "
        f"[{html.escape(n['pod'])}] {html.escape(n['text'])}</li>"
        for n in store.list()
    )
    return f"""<!doctype html>
<html><head><title>notes-app</title></head>
<body style="font-family: sans-serif; max-width: 48rem; margin: 2rem auto;">
<h1>{html.escape(APP_GREETING)}</h1>
<table>
<tr><td>Version</td><td>{html.escape(APP_VERSION)}</td></tr>
<tr><td>Environment</td><td>{html.escape(APP_ENV)}</td></tr>
<tr><td>Served by pod</td><td>{html.escape(POD)}</td></tr>
<tr><td>Storage</td><td>{store.name}</td></tr>
<tr><td>API token</td><td>{html.escape(token_status())}</td></tr>
</table>
<h2>Notes</h2>
<form method="post" action="/notes">
<input name="text" size="40" required> <button>Add note</button>
</form>
<ul>{items}</ul>
</body></html>"""


@app.post("/notes")
def add_note_form():
    text = request.form.get("text", "").strip()
    if text:
        store.add(text)
        log.info("note added pod=%s", POD)
    return redirect("/", code=303)


@app.get("/api/info")
def info():
    return jsonify(
        version=APP_VERSION,
        environment=APP_ENV,
        greeting=APP_GREETING,
        pod=POD,
        storage=store.name,
        api_token=token_status(),
    )


@app.get("/api/notes")
def list_notes():
    return jsonify(store.list())


@app.post("/api/notes")
def add_note_api():
    text = (request.get_json(silent=True) or {}).get("text", "").strip()
    if not text:
        return jsonify(error="text is required"), 400
    store.add(text)
    log.info("note added pod=%s", POD)
    return jsonify(status="created", pod=POD), 201


@app.get("/healthz/live")
def live():
    return jsonify(status="ok")


@app.get("/healthz/ready")
def ready():
    if store.ping():
        return jsonify(status="ready", storage=store.name)
    return jsonify(status="not ready", storage=store.name), 503


if __name__ == "__main__":
    # Development server - this is how the "legacy" image starts the app.
    log.info("starting development server on port %s", PORT)
    app.run(host="0.0.0.0", port=PORT)
