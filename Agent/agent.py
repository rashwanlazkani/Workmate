"""Push-driven reminder runner: MQTT changes, durable local timers, HTTPS delivery."""
import json
import logging
import os
from pathlib import Path
import signal
import sqlite3
import ssl
import sys
import threading
import time
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import HTTPError

log = logging.getLogger("workmate")
TERMINAL = {"delivered", "duplicate", "canceled", "skipped"}

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
            raise RuntimeError("Reminder API returned HTTP %s" % error.code) from None

class Runner:
    def __init__(self, path, api, clock=time.time):
        self.db = sqlite3.connect(path)
        self.api = api
        self.clock = clock
        self.offset = 0
        self.ready = False
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, fire REAL, expires REAL, state TEXT, retry REAL DEFAULT 0, attempts INTEGER DEFAULT 0)")
        self.db.execute("CREATE TABLE IF NOT EXISTS runtime (id INTEGER PRIMARY KEY, last_alive REAL, connected INTEGER, ready INTEGER)")
        self.db.commit()

    def refresh(self):
        plan = self.api.request("/plan")
        self.offset = timestamp(plan["serverTime"]) - self.clock()
        jobs = plan["jobs"]
        ids = {j["id"] for j in jobs}
        with self.db:
            for row in self.db.execute("SELECT id FROM jobs").fetchall():
                if row[0] not in ids:
                    self.db.execute("DELETE FROM jobs WHERE id=?", row)
            for job in jobs:
                self.db.execute("INSERT INTO jobs(id,fire,expires,state) VALUES(?,?,?,'pending') ON CONFLICT(id) DO UPDATE SET fire=excluded.fire, expires=excluded.expires",
                                (job["id"], timestamp(job["fireAt"]), timestamp(job["expiresAt"])))
        self.ready = True
        log.info("Schedule synchronized; %d pending timers", self.db.execute("SELECT count(*) FROM jobs WHERE state='pending'").fetchone()[0])

    def deliver_due(self):
        if not self.ready:
            return False
        now = self.clock() + self.offset
        with self.db:
            expired = self.db.execute("UPDATE jobs SET state='expired' WHERE state='pending' AND expires<=?", (now,)).rowcount
        changed = bool(expired)
        rows = self.db.execute("SELECT id,attempts FROM jobs WHERE state='pending' AND fire<=? AND expires>? AND retry<=? ORDER BY fire LIMIT 100", (now, now, now)).fetchall()
        for job_id, attempts in rows:
            try:
                # The server revalidates cancellation, opt-out and changed times before sending.
                status = self.api.request("/deliver", {"id": job_id})["status"]
                if status in TERMINAL:
                    with self.db:
                        self.db.execute("UPDATE jobs SET state=? WHERE id=?", (status, job_id))
                    changed = True
                    log.info("Reminder result: %s", status)
                    continue
                if status != "pending":
                    raise ValueError("Unexpected delivery status")
            except Exception as error:
                log.warning("Delivery retry scheduled: %s", type(error).__name__)
            with self.db:
                self.db.execute("UPDATE jobs SET retry=?, attempts=attempts+1 WHERE id=?", (now + min(300, 15 * 2 ** min(attempts, 5)), job_id))
        return changed

    def next_delay(self):
        if not self.ready:
            return None
        row = self.db.execute("SELECT min(min(max(fire,retry),expires)) FROM jobs WHERE state='pending'").fetchone()
        return None if row[0] is None else max(0, row[0] - (self.clock() + self.offset))

    def heartbeat(self, connected):
        # Local Docker health only. This never calls AWS.
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO runtime VALUES(1,?,?,?)", (self.clock(), bool(connected), self.ready))

def healthcheck(path):
    try:
        with sqlite3.connect(path) as db:
            row = db.execute("SELECT last_alive,connected,ready FROM runtime WHERE id=1").fetchone()
        return bool(row and time.time() - row[0] < 180 and row[1] and row[2])
    except sqlite3.Error:
        return False

class PushConnection:
    def __init__(self, config, wake, refresh):
        import paho.mqtt.client as mqtt
        self.connected = threading.Event()
        self.wake = wake
        self.refresh = refresh
        self.topic = config["topic"]
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=config["clientID"], clean_session=False)
        context = ssl.create_default_context()
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(config["certificateFile"], config["privateKeyFile"])
        self.client.tls_set_context(context)
        self.client.reconnect_delay_set(min_delay=1, max_delay=60)
        self.client.on_connect = self.on_connect
        self.client.on_subscribe = self.on_subscribe
        self.client.on_message = self.on_message
        self.client.on_disconnect = self.on_disconnect
        self.client.connect_async(config["endpoint"], port=8883, keepalive=60)

    def on_connect(self, client, userdata, flags, reason_code, properties):
        if reason_code.is_failure:
            log.warning("Push connection rejected")
            return
        client.subscribe(self.topic, qos=1)

    def on_subscribe(self, client, userdata, mid, reason_codes, properties):
        if not reason_codes or any(code.is_failure for code in reason_codes):
            log.error("Push subscription rejected")
            client.disconnect()
            return
        self.connected.set()
        self.refresh.set()  # Catch up once after every reconnect, including an expired broker session.
        self.wake.set()
        log.info("Push connected and subscribed")

    def on_message(self, client, userdata, message):
        if message.topic != self.topic:
            return
        try:
            if len(message.payload) > 1024 or json.loads(message.payload).get("kind") != "schedule.changed":
                return
        except (ValueError, AttributeError):
            return
        self.refresh.set()  # Coalesce bursts; timers and SQLite stay on the main thread.
        self.wake.set()
        log.info("Schedule change received")

    def on_disconnect(self, client, userdata, flags, reason_code, properties):
        self.connected.clear()
        self.wake.set()
        log.info("Push disconnected; reconnecting")

    def start(self):
        self.client.loop_start()

    def close(self):
        self.client.disconnect()
        self.client.loop_stop()

def main():
    path = os.getenv("WORKMATE_DATABASE", "/data/agent.sqlite")
    if "--healthcheck" in sys.argv:
        raise SystemExit(0 if healthcheck(path) else 1)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    config = json.loads(Path(os.getenv("WORKMATE_CONNECTION", "/run/secrets/connection.json")).read_text())
    runner = Runner(path, API(config))
    stop, wake, refresh = threading.Event(), threading.Event(), threading.Event()
    def shutdown(*_):
        stop.set(); wake.set()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, shutdown)
    push = PushConnection(config["mqtt"], wake, refresh)
    retry_at, failures = None, 0
    push.start()
    log.info("Workmate push reminder agent started; no periodic plan polling")
    try:
        while not stop.is_set():
            wake.clear()
            if refresh.is_set() or (retry_at is not None and time.monotonic() >= retry_at):
                refresh.clear()
                try:
                    runner.refresh(); retry_at = None; failures = 0
                except Exception as error:
                    failures += 1
                    retry_at = time.monotonic() + min(300, 2 ** min(failures, 8))
                    log.warning("Schedule sync retry scheduled: %s", type(error).__name__)
            if runner.deliver_due():
                # Replenish recurring occurrences after a timer finishes, never by idle polling.
                refresh.set()
            runner.heartbeat(push.connected.is_set())
            if refresh.is_set():
                continue
            waits = [30.0]  # Local health write, not a network request.
            delay = runner.next_delay()
            if delay is not None: waits.append(delay)
            if retry_at is not None: waits.append(max(0, retry_at - time.monotonic()))
            wake.wait(min(waits))
    finally:
        push.close()
        runner.heartbeat(False)
        runner.db.close()

if __name__ == "__main__":
    main()
