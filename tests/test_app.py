"""
Unit tests for the app's request logic: python3 -m unittest discover -s tests -v
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
import app  # noqa: E402


class AppTests(unittest.TestCase):
    def setUp(self):
        app.state.update({"ready": True, "requests": 0, "work_ms_total": 0})

    def test_health_is_alive(self):
        code, _, body = app.handle("/health")
        self.assertEqual(code, 200)
        self.assertIn(b"alive", body)

    def test_ready_then_unready_then_ready_again(self):
        self.assertEqual(app.handle("/ready")[0], 200)
        app.handle("/unready")
        self.assertEqual(app.handle("/ready")[0], 503)
        app.handle("/ready-on")
        self.assertEqual(app.handle("/ready")[0], 200)

    def test_liveness_unaffected_by_readiness(self):
        app.handle("/unready")
        self.assertEqual(app.handle("/health")[0], 200)

    def test_info_reports_config_without_leaking_the_secret(self):
        env = {"GREETING": "hello test", "API_KEY": "super-secret-value"}
        code, _, body = app.handle("/info", environ=env, hostname="pod-1")
        data = json.loads(body)
        self.assertEqual(code, 200)
        self.assertEqual(data["pod"], "pod-1")
        self.assertEqual(data["greeting"], "hello test")
        self.assertTrue(data["api_key_configured"])
        self.assertNotIn(b"super-secret-value", body)

    def test_info_without_secret(self):
        _, _, body = app.handle("/info", environ={}, hostname="p")
        self.assertFalse(json.loads(body)["api_key_configured"])

    def test_work_burns_requested_time_and_is_clamped(self):
        self.assertEqual(app.parse_ms("ms=50"), 50)
        self.assertEqual(app.parse_ms("ms=999999"), app.MAX_WORK_MS)
        self.assertEqual(app.parse_ms("ms=abc"), 0)
        self.assertEqual(app.parse_ms("ms=-5"), 0)
        self.assertEqual(app.parse_ms(""), 100)

    def test_work_updates_metrics(self):
        app.handle("/work?ms=10")
        _, _, body = app.handle("/metrics")
        self.assertIn(b"shop_api_work_milliseconds_total 10", body)

    def test_metrics_format(self):
        app.handle("/health")
        code, ctype, body = app.handle("/metrics")
        self.assertEqual(code, 200)
        self.assertTrue(ctype.startswith("text/plain"))
        self.assertIn(b"shop_api_requests_total", body)
        self.assertIn(b"shop_api_ready 1", body)

    def test_unknown_route_is_404(self):
        self.assertEqual(app.handle("/nope")[0], 404)


if __name__ == "__main__":
    unittest.main()