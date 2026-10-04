import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tempfile
import unittest
from agent import Runner, timestamp

NOW = "2026-10-07T11:00:00Z"
class API:
    def __init__(self):
        self.jobs = [{"id": "a", "fireAt": NOW, "expiresAt": "2026-10-07T12:00:00Z"}]
        self.calls = []
        self.fail = False
        self.now = NOW
    def request(self, path, body=None):
        if path == "/plan": return {"jobs": self.jobs, "serverTime": self.now}
        self.calls.append(body["id"])
        if self.fail: raise OSError("network unavailable")
        return {"status": "delivered"}

class AgentTests(unittest.TestCase):
    def test_restart_preserves_completed_jobs_and_uses_server_clock(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); db = str(Path(folder) / "test.sqlite")
            runner = Runner(db, api, lambda: 0)
            runner.tick(); runner.db.close()
            runner = Runner(db, api); runner.tick(); runner.db.close()
            self.assertEqual(api.calls, ["a"])
    def test_retry_survives_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); api.fail = True; db = str(Path(folder) / "test.sqlite")
            runner = Runner(db, api); runner.tick(); runner.db.close()
            api.fail = False; api.now = "2026-10-07T11:01:00Z"
            runner = Runner(db, api); runner.tick(); runner.db.close()
            self.assertEqual(api.calls, ["a", "a"])
    def test_cancellation_removes_pending_delivery_after_outage(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); api.fail = True
            runner = Runner(str(Path(folder)/"test.sqlite"), api)
            runner.tick(); api.jobs = []; api.fail = False
            api.now = "2026-10-07T11:01:00Z"; runner.tick()
            self.assertEqual(api.calls, ["a"])
            self.assertEqual(runner.db.execute("SELECT count(*) FROM jobs").fetchone()[0], 0)
            runner.db.close()
    def test_future_and_expired_jobs_are_not_sent(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); api.jobs[0]["fireAt"] = "2026-10-07T11:10:00Z"
            runner = Runner(str(Path(folder)/"test.sqlite"), api); runner.tick()
            api.now = "2026-10-07T13:00:00Z"; runner.tick()
            self.assertEqual(api.calls, []); runner.db.close()

if __name__ == "__main__": unittest.main()
