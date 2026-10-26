#!/usr/bin/env python3
"""Replay logged live-suggestion / Sidecast calls against another model or prompt
and have a judge model compare the new answer with the one the app produced.

Traces come from Settings > Troubleshooting > "Log live suggestions for evals".
Requires an OpenAI-compatible endpoint (OpenRouter by default). Stdlib only.
"""
import argparse
import concurrent.futures
import json
import os
import random
import sys
import time
import urllib.request
from pathlib import Path

DEFAULT_TRACES = Path.home() / "Library/Application Support/OpenOats/llm-traces"

RUBRICS = {
    "suggestion": (
        "A live meeting copilot whispers a short card to the listener while the conversation "
        "is happening. The better card is the one the listener would be glad to glance at right now: "
        "specific (names, numbers, quotes from the evidence), accurate to the evidence, actionable, "
        "scannable in a few seconds. Penalize filler, hedging, vague summaries and invented facts. "
        "Do not reward length."
    ),
    "sidecast": (
        "Sidecast shows short persona bubbles beside a live conversation. Each output is JSON with "
        "the messages the personas want to say (speak=true). The better output gives the host "
        "non-obvious facts, sharp reframes or useful corrections that fit each persona. "
        "Silence (no messages) beats filler; generic, obvious or wrong bubbles count against an output. "
        "Do not reward more messages for their own sake."
    ),
}

JUDGE_TEMPLATE = """{rubric}

Context the model was given:
<context>
{context}
</context>

Output A:
<a>
{a}
</a>

Output B:
<b>
{b}
</b>

Reply with JSON only: {{"winner": "A" | "B" | "tie", "reason": "one sentence"}}"""


def load_traces(paths, engine, include_all):
    files = []
    for p in paths:
        p = Path(p).expanduser()
        files += sorted(p.glob("*.jsonl")) if p.is_dir() else [p]
    traces = []
    for f in files:
        for number, line in enumerate(f.read_text().splitlines(), 1):
            if not line.strip():
                continue
            try:
                t = json.loads(line)
            except ValueError:
                # A crash mid-write leaves a partial line; drop it rather than the whole run.
                print(f"skipping unreadable trace {f.name}:{number}", file=sys.stderr)
                continue
            if engine and t["engine"] != engine:
                continue
            if not include_all and t["outcome"] != "completed":
                continue
            traces.append(t)
    return traces


def apply_overrides(messages, system=None, replacements=None):
    out = []
    for m in messages:
        content = system if (system is not None and m["role"] == "system") else m["content"]
        for old, new in (replacements or {}).items():
            content = content.replace(old, new)
        out.append({"role": m["role"], "content": content})
    return out


def chat(base_url, api_key, body, timeout=120):
    """Streams a chat completion. Returns (text, first_token_ms, total_ms)."""
    req = urllib.request.Request(
        base_url.rstrip("/") + "/chat/completions",
        data=json.dumps({**body, "stream": True}).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
    )
    start = time.monotonic()
    first = None
    parts = []
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            choices = json.loads(data).get("choices") or [{}]
            delta = (choices[0].get("delta") or {}).get("content") or ""
            if delta and first is None:
                first = int((time.monotonic() - start) * 1000)
            parts.append(delta)
    return "".join(parts), first, int((time.monotonic() - start) * 1000)


def strip_fence(text):
    s = text.strip()
    if s.startswith("```json"):
        s = s[7:]
    elif s.startswith("```"):
        s = s[3:]
    if s.endswith("```"):
        s = s[:-3]
    return s.strip()


def sidecast_valid(text):
    try:
        return isinstance(json.loads(strip_fence(text)).get("messages"), list)
    except (ValueError, AttributeError):
        return False


def parse_verdict(text):
    try:
        verdict = json.loads(strip_fence(text))
        winner = str(verdict.get("winner", "")).strip().upper()
        return (winner if winner in ("A", "B") else "tie"), verdict.get("reason", "")
    except (ValueError, AttributeError):
        return "tie", f"unparseable judge reply: {text[:200]}"


def percentile(values, q):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def run_one(trace, args, system, replacements, api_key, rng_seed):
    messages = apply_overrides(trace["messages"], system, replacements)
    body = {
        "model": args.model or trace["model"],
        "messages": messages,
        "max_tokens": trace["maxTokens"],
        **args.extra,
    }
    temperature = args.temperature if args.temperature is not None else trace.get("temperature")
    if temperature is not None:
        body["temperature"] = temperature
    if trace.get("webSearch"):
        # Same OpenRouter plugin the app sends (OpenRouterClient.WebSearchPlugin.default).
        body["plugins"] = [{"id": "web", "max_results": 5}]
    result = {"id": trace["id"], "engine": trace["engine"], "startedAt": trace["startedAt"],
              "baselineModel": trace["model"], "candidateModel": body["model"],
              "baseline": trace["response"], "baselineFirstTokenMs": trace.get("firstTokenMs"),
              "baselineTotalMs": trace["totalMs"]}
    try:
        text, first, total = chat(args.base_url, api_key, body)
        result.update(candidate=text, candidateFirstTokenMs=first, candidateTotalMs=total)
    except Exception as e:  # noqa: BLE001 - one failed call must not stop the run
        result.update(candidate=None, error=str(e))
        return result

    # Shuffle positions so the judge's position bias does not favor either side.
    candidate_first = random.Random(rng_seed).random() < 0.5
    a, b = (text, trace["response"]) if candidate_first else (trace["response"], text)
    result.update(candidateFirst=candidate_first, a=a, b=b,
                  rubric=args.rubric or RUBRICS[trace["engine"]],
                  context="\n\n".join(m["content"] for m in trace["messages"] if m["role"] != "system"))

    if args.judge_model:
        prompt = JUDGE_TEMPLATE.format(rubric=result["rubric"], context=result["context"], a=a, b=b)
        try:
            reply, _, _ = chat(args.base_url, api_key, {
                "model": args.judge_model, "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 300, "temperature": 0})
            winner, reason = parse_verdict(reply)
        except Exception as e:  # noqa: BLE001
            winner, reason = "tie", f"judge error: {e}"
        result.update(verdict=credit(winner, candidate_first), reason=reason)
    return result


def credit(winner, candidate_first):
    """Maps a blind A/B/tie pick back to candidate/baseline/tie."""
    if winner == "tie":
        return "tie"
    if (winner == "A") == candidate_first:
        return "candidate"
    return "baseline"


def write_pack(results, path):
    """Blind pairs for judging outside this script (e.g. in Claude Code): no model names or latencies."""
    with path.open("w") as fh:
        for r in results:
            if r.get("candidate") is not None:
                pair = {k: r[k] for k in ("id", "engine", "rubric", "context", "a", "b")}
                fh.write(json.dumps(pair, ensure_ascii=False) + "\n")


def apply_verdicts(results, verdicts):
    """Merges {"id", "winner": "A"|"B"|"tie", "reason"} lines into results."""
    by_id = {v["id"]: v for v in verdicts}
    for r in results:
        v = by_id.get(r["id"])
        if v and r.get("candidate") is not None:
            winner = str(v.get("winner", "")).strip().upper()
            winner = winner if winner in ("A", "B") else "tie"
            r.update(verdict=credit(winner, r["candidateFirst"]), reason=v.get("reason", ""))
    return results


def summarize(results):
    ok = [r for r in results if r.get("candidate") is not None]
    lines = [f"traces: {len(results)}  candidate errors: {len(results) - len(ok)}"]
    verdicts = [r["verdict"] for r in ok if "verdict" in r]
    if verdicts:
        n = len(verdicts)
        c, b, t = (verdicts.count(k) for k in ("candidate", "baseline", "tie"))
        lines.append(f"judge: candidate {c} / baseline {b} / tie {t}  "
                     f"(candidate win rate excluding ties: {c / max(1, c + b):.0%})")
        lines.append(f"       candidate wins or ties: {(c + t) / n:.0%}")
    for label, key in (("first token", "FirstTokenMs"), ("total", "TotalMs")):
        base = [r[f"baseline{key}"] for r in ok]
        cand = [r[f"candidate{key}"] for r in ok]
        if any(v is not None for v in base + cand):
            lines.append(f"{label} ms  baseline p50 {percentile(base, .5)} p95 {percentile(base, .95)}  |  "
                         f"candidate p50 {percentile(cand, .5)} p95 {percentile(cand, .95)}")
    sidecast = [r for r in ok if r["engine"] == "sidecast"]
    if sidecast:
        valid = sum(sidecast_valid(r["candidate"]) for r in sidecast)
        lines.append(f"sidecast candidate valid JSON: {valid}/{len(sidecast)}")
    return "\n".join(lines)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("traces", nargs="*", default=[str(DEFAULT_TRACES)], help="trace files or directories")
    p.add_argument("--engine", choices=["suggestion", "sidecast"])
    p.add_argument("--model", help="candidate model (default: the model in each trace)")
    p.add_argument("--system", type=Path, help="file that replaces the system prompt")
    p.add_argument("--replace", type=Path, help='JSON file {"old text": "new text"} applied to every message, '
                                                 "e.g. to edit one persona's prompt")
    p.add_argument("--temperature", type=float)
    p.add_argument("--extra", type=json.loads, default={}, help="JSON merged into each request body")
    p.add_argument("--judge-model", help="model that compares baseline and candidate (skip to only replay)")
    p.add_argument("--rubric", help="override the judge rubric text")
    p.add_argument("--all-outcomes", action="store_true", help="also replay superseded/failed traces")
    p.add_argument("--limit", type=int)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--concurrency", type=int, default=4)
    p.add_argument("--base-url", default="https://openrouter.ai/api/v1")
    p.add_argument("--api-key-env", default="OPENROUTER_API_KEY")
    p.add_argument("--out", type=Path, default=Path("eval-results.jsonl"))
    p.add_argument("--pack", type=Path, default=Path("eval-pack.jsonl"),
                   help="blind A/B pairs written when --judge-model is not set")
    p.add_argument("--verdicts", type=Path,
                   help="score an earlier run: merge these verdicts into --out and print the summary")
    args = p.parse_args(argv)

    if args.verdicts:
        results = [json.loads(line) for line in args.out.read_text().splitlines() if line.strip()]
        verdicts = [json.loads(line) for line in args.verdicts.read_text().splitlines() if line.strip()]
        save_results(apply_verdicts(results, verdicts), args.out)
        print(summarize(results))
        return

    api_key = os.environ.get(args.api_key_env)
    if not api_key:
        sys.exit(f"Set {args.api_key_env}")
    traces = load_traces(args.traces, args.engine, args.all_outcomes)
    random.Random(args.seed).shuffle(traces)
    traces = traces[: args.limit] if args.limit else traces
    if not traces:
        sys.exit("No matching traces. Enable logging in Settings > Troubleshooting first.")
    system = args.system.read_text() if args.system else None
    replacements = json.loads(args.replace.read_text()) if args.replace else None

    with concurrent.futures.ThreadPoolExecutor(args.concurrency) as pool:
        futures = [pool.submit(run_one, t, args, system, replacements, api_key, args.seed + i)
                   for i, t in enumerate(traces)]
        results = []
        for i, f in enumerate(concurrent.futures.as_completed(futures), 1):
            results.append(f.result())
            print(f"\r{i}/{len(traces)}", end="", file=sys.stderr, flush=True)
    print(file=sys.stderr)

    save_results(results, args.out)
    print(summarize(results))
    print(f"details: {args.out}")
    if not args.judge_model:
        write_pack(results, args.pack)
        print(f"blind pairs to judge: {args.pack}")


def save_results(results, path):
    with path.open("w") as fh:
        for r in results:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
