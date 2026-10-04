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
        self.reads = 0
        self.status = "delivered"
    def request(self, path, body=None):
        if path == "/plan":
            self.reads += 1
            return {"jobs": self.jobs, "serverTime": self.now}
        self.calls.append(body["id"])
        if self.fail: raise OSError("network unavailable")
        return {"status": self.status}

class AgentTests(unittest.TestCase):
    def test_idle_timer_does_not_poll_cloud(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); api.jobs[0]["fireAt"] = "2026-10-07T11:10:00Z"
            clock = [0]
            runner = Runner(str(Path(folder)/"test.sqlite"), api, lambda: clock[0])
            runner.refresh()
            self.assertEqual(runner.next_delay(), 600)
            for i in range(10):
                clock[0] = i * 30
                self.assertFalse(runner.deliver_due()); runner.heartbeat(True)
            self.assertEqual(api.reads, 1); self.assertEqual(api.calls, [])
            clock[0] = 600
            self.assertTrue(runner.deliver_due()); self.assertEqual(api.calls, ["a"])
            self.assertIsNone(runner.next_delay()); runner.db.close()
    def test_restart_preserves_completed_jobs_and_uses_server_clock(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); db = str(Path(folder) / "test.sqlite")
            runner = Runner(db, api, lambda: 0)
            runner.refresh(); runner.deliver_due(); runner.db.close()
            runner = Runner(db, api); runner.refresh(); runner.deliver_due(); runner.db.close()
            self.assertEqual(api.calls, ["a"])
    def test_retry_survives_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); api.fail = True; db = str(Path(folder) / "test.sqlite")
            runner = Runner(db, api); runner.refresh(); runner.deliver_due(); runner.db.close()
            api.fail = False; api.now = "2026-10-07T11:01:00Z"
            runner = Runner(db, api); runner.refresh(); runner.deliver_due(); runner.db.close()
            self.assertEqual(api.calls, ["a", "a"])
    def test_change_event_cancels_pending_timer(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); api.jobs[0]["fireAt"] = "2026-10-07T11:10:00Z"
            runner = Runner(str(Path(folder)/"test.sqlite"), api)
            runner.refresh(); api.jobs = []; runner.refresh()
            self.assertIsNone(runner.next_delay()); runner.deliver_due()
            self.assertEqual(api.calls, []); runner.db.close()
    def test_stale_timer_is_revalidated_by_server(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); api.status = "canceled"
            runner = Runner(str(Path(folder)/"test.sqlite"), api)
            runner.refresh(); self.assertTrue(runner.deliver_due())
            self.assertEqual(runner.db.execute("SELECT state FROM jobs").fetchone()[0], "canceled")
            self.assertIsNone(runner.next_delay()); runner.db.close()
    def test_empty_plan_waits_for_push_without_polling(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); api.jobs = []
            runner = Runner(str(Path(folder)/"test.sqlite"), api)
            runner.refresh()
            for _ in range(20): runner.deliver_due()
            self.assertIsNone(runner.next_delay()); self.assertEqual(api.reads, 1)
            runner.db.close()
    def test_expired_occurrence_requests_recurring_replenishment(self):
        with tempfile.TemporaryDirectory() as folder:
            api = API(); clock = [0]
            runner = Runner(str(Path(folder)/"test.sqlite"), api, lambda: clock[0])
            runner.refresh(); clock[0] = 3601
            self.assertTrue(runner.deliver_due()); self.assertEqual(api.calls, [])
            self.assertIsNone(runner.next_delay()); runner.db.close()

if __name__ == "__main__": unittest.main()
