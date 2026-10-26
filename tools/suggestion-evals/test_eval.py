import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import eval as ev


class EvalTests(unittest.TestCase):
    def test_overrides_replace_system_and_substitute_text(self):
        messages = [{"role": "system", "content": "old system"},
                    {"role": "user", "content": "prompt: be funny"}]
        out = ev.apply_overrides(messages, "new system", {"be funny": "be dry"})
        self.assertEqual(out, [{"role": "system", "content": "new system"},
                               {"role": "user", "content": "prompt: be dry"}])
        self.assertEqual(messages[1]["content"], "prompt: be funny")

    def test_parse_verdict(self):
        self.assertEqual(ev.parse_verdict('```json\n{"winner":"b","reason":"x"}\n```'), ("B", "x"))
        self.assertEqual(ev.parse_verdict("not json")[0], "tie")

    def test_percentile_ignores_missing(self):
        self.assertEqual(ev.percentile([None, 300, 100, 200], 0.5), 200)
        self.assertIsNone(ev.percentile([None], 0.5))

    def test_load_traces_filters_engine_and_outcome(self):
        rows = [{"engine": "sidecast", "outcome": "completed"},
                {"engine": "sidecast", "outcome": "superseded"},
                {"engine": "suggestion", "outcome": "completed"}]
        with tempfile.TemporaryDirectory() as d:
            Path(d, "2026-10-22.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            self.assertEqual(len(ev.load_traces([d], "sidecast", False)), 1)
            self.assertEqual(len(ev.load_traces([d], None, True)), 3)

    def test_load_traces_skips_truncated_line(self):
        good = json.dumps({"engine": "sidecast", "outcome": "completed"})
        with tempfile.TemporaryDirectory() as d:
            Path(d, "2026-10-22.jsonl").write_text(f'{good}\n{{"engine": "sidec\n{good}\n')
            with contextlib.redirect_stderr(io.StringIO()) as err:
                traces = ev.load_traces([d], None, True)
        self.assertEqual(len(traces), 2)
        self.assertIn("2026-10-22.jsonl:2", err.getvalue())

    def test_run_one_credits_judge_pick_to_candidate_in_either_position(self):
        trace = {"id": "1", "engine": "sidecast", "startedAt": "t", "model": "m", "maxTokens": 100,
                 "temperature": 0.5, "webSearch": True, "messages": [{"role": "user", "content": "ctx"}],
                 "response": "OLD", "firstTokenMs": None, "totalMs": 900}
        args = ev.argparse.Namespace(model="cand", temperature=None, extra={}, judge_model="judge",
                                     rubric=None, base_url="http://unused")
        requests = []

        def fake_chat(base_url, api_key, body, timeout=120):
            requests.append(body)
            if body["model"] == "judge":
                prompt = body["messages"][0]["content"]
                return json.dumps({"winner": "A" if "<a>\nNEW" in prompt else "B"}), None, 5
            return "NEW", 10, 20

        original, ev.chat = ev.chat, fake_chat
        try:
            # Seeds 0..9 cover both the candidate-first and baseline-first orderings.
            verdicts = {ev.run_one(trace, args, None, None, "key", seed)["verdict"] for seed in range(10)}
        finally:
            ev.chat = original
        self.assertEqual(verdicts, {"candidate"})
        self.assertEqual(requests[0]["plugins"], [{"id": "web", "max_results": 5}])

    def test_external_verdicts_unblind_and_pack_hides_models(self):
        results = [{"id": "1", "engine": "suggestion", "candidate": "NEW", "candidateFirst": True,
                    "rubric": "r", "context": "c", "a": "NEW", "b": "OLD", "candidateModel": "secret"},
                   {"id": "2", "engine": "suggestion", "candidate": "NEW", "candidateFirst": False,
                    "rubric": "r", "context": "c", "a": "OLD", "b": "NEW"}]
        ev.apply_verdicts(results, [{"id": "1", "winner": "a"}, {"id": "2", "winner": "A"}])
        self.assertEqual([r["verdict"] for r in results], ["candidate", "baseline"])
        with tempfile.TemporaryDirectory() as d:
            pack = Path(d, "pack.jsonl")
            ev.write_pack(results, pack)
            self.assertNotIn("secret", pack.read_text())
            self.assertNotIn("candidateFirst", pack.read_text())

    def test_summary_maps_judge_verdicts(self):
        results = [{"engine": "sidecast", "candidate": '{"messages":[]}', "verdict": "candidate",
                    "baselineFirstTokenMs": None, "baselineTotalMs": 900,
                    "candidateFirstTokenMs": 200, "candidateTotalMs": 700},
                   {"engine": "sidecast", "candidate": "oops", "verdict": "baseline",
                    "baselineFirstTokenMs": None, "baselineTotalMs": 1100,
                    "candidateFirstTokenMs": 250, "candidateTotalMs": 800}]
        summary = ev.summarize(results)
        self.assertIn("candidate 1 / baseline 1 / tie 0", summary)
        self.assertIn("valid JSON: 1/2", summary)


if __name__ == "__main__":
    unittest.main()
