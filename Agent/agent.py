"""Workmate reminder runner. Outbound HTTPS only; no workspace or bot secrets."""
import json
import logging
import os
from pathlib import Path
import signal
import sqlite3
import sys
import threading
import time
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import HTTPError

log = logging.getLogger("workmate")

def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()

class API:
    def __init__(self, config):
        self.url = config["apiURL"].rstrip("/") + "/agent"
        if not self.url.startswith("https://"):
            raise ValueError("The reminder API must use HTTPS")
        self.token = config["token"]

    def request(self, path, body=None):
        request = Request(self.url + path, data=json.dumps(body).encode() if body is not None else None,
                          headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        try:
            with urlopen(request, timeout=20) as response:
                return json.load(response)
        except HTTPError as error:
            # Avoid logging headers, request bodies, private keys or notification text.
            raise RuntimeError("Reminder API returned HTTP %s" % error.code) from None

class Runner:
    def __init__(self, path, api, clock=time.time):
        self.db = sqlite3.connect(path)
        self.api = api
        self.clock = clock
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, fire REAL, expires REAL, state TEXT, retry REAL DEFAULT 0, attempts INTEGER DEFAULT 0)")
        self.db.execute("CREATE TABLE IF NOT EXISTS health (id INTEGER PRIMARY KEY, last_poll REAL)")
        self.db.commit()

    def tick(self):
        # Reconcile before delivery: canceled tasks and changed times are removed even after downtime.
        plan = self.api.request("/plan")
        server_now = timestamp(plan["serverTime"])
        jobs = plan["jobs"]
        ids = {j["id"] for j in jobs}
        with self.db:
            for row in self.db.execute("SELECT id FROM jobs").fetchall():
                if row[0] not in ids:
                    self.db.execute("DELETE FROM jobs WHERE id=?", row)
            for job in jobs:
                self.db.execute("INSERT INTO jobs(id,fire,expires,state) VALUES(?,?,?,'pending') ON CONFLICT(id) DO UPDATE SET fire=excluded.fire, expires=excluded.expires",
                                (job["id"], timestamp(job["fireAt"]), timestamp(job["expiresAt"])))
            self.db.execute("INSERT OR REPLACE INTO health VALUES(1,?)", (self.clock(),))
        rows = self.db.execute("SELECT id,attempts FROM jobs WHERE state='pending' AND fire<=? AND expires>? AND retry<=? ORDER BY fire LIMIT 100", (server_now, server_now, server_now)).fetchall()
        for job_id, attempts in rows:
            try:
                status = self.api.request("/deliver", {"id": job_id})["status"]
                if status in ("delivered", "duplicate", "canceled", "skipped"):
                    with self.db:
                        self.db.execute("UPDATE jobs SET state=? WHERE id=?", (status, job_id))
                    log.info("Reminder result: %s", status)
                    continue
                if status != "pending":
                    raise ValueError("Unexpected delivery status")
            except Exception as error:
                log.warning("Delivery retry scheduled: %s", type(error).__name__)
            with self.db:
                self.db.execute("UPDATE jobs SET retry=?, attempts=attempts+1 WHERE id=?", (server_now + min(300, 15 * 2 ** min(attempts, 5)), job_id))

def healthcheck(path):
    try:
        with sqlite3.connect(path) as db:
            row = db.execute("SELECT last_poll FROM health WHERE id=1").fetchone()
        return bool(row and time.time() - row[0] < 180)
    except sqlite3.Error:
        return False

def main():
    path = os.getenv("WORKMATE_DATABASE", "/data/agent.sqlite")
    if "--healthcheck" in sys.argv:
        raise SystemExit(0 if healthcheck(path) else 1)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    config_path = os.getenv("WORKMATE_CONNECTION", "/run/secrets/connection.json")
    config = json.loads(Path(config_path).read_text())
    runner = Runner(path, API(config))
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    log.info("Workmate reminder agent started")
    try:
        while not stop.is_set():
            try:
                runner.tick()
            except Exception as error:
                log.warning("Plan refresh failed: %s", type(error).__name__)
            stop.wait(15)
    finally:
        runner.db.close()

if __name__ == "__main__":
    main()
