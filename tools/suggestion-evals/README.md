# Suggestion evals

Replays logged live-suggestion and Sidecast LLM calls against another model or prompt, then asks a judge model which answer is better than the one the app actually showed.

## 1. Collect traces

Turn on **Settings → Troubleshooting → Log live suggestions for evals**, then run a few meetings. Each call is appended to
`~/Library/Application Support/OpenOats/llm-traces/YYYY-MM-DD.jsonl` with the exact messages sent, the raw response, what reached the UI (`shown`), model, provider, `firstTokenMs` / `totalMs` and the outcome (`completed`, `superseded`, `failed`, `parse_error`).

## 2. Run an eval

```sh
export OPENROUTER_API_KEY=...

# Another model, same prompts
python3 eval.py --engine suggestion --model google/gemini-2.5-flash --judge-model anthropic/claude-sonnet-4.5

# Tweak one Sidecast persona: swap text inside the logged prompt
echo '{"prompt: Be the skeptic": "prompt: Be the skeptic. Only push back with a number."}' > persona.json
python3 eval.py --engine sidecast --replace persona.json --judge-model anthropic/claude-sonnet-4.5 --limit 40

# Whole new Sidecast system prompt
python3 eval.py --engine sidecast --system my-system-prompt.txt --judge-model anthropic/claude-sonnet-4.5
```

Without `--judge-model` it replays, reports latency and writes blind A/B pairs to `eval-pack.jsonl` (see below). Per-trace results (both answers, latencies, verdict and the judge's reason) go to `eval-results.jsonl`.

### Judging in Claude Code instead of a judge model

1. Run without `--judge-model`, e.g. `python3 eval.py --engine sidecast --replace persona.json --limit 30`.
2. Ask Claude Code: *"Judge tools/suggestion-evals/eval-pack.jsonl into eval-verdicts.jsonl"*. Each pack line has the rubric, the context and outputs `a` / `b` with no model names, so the judge cannot tell which side is new. Write one line per pair: `{"id": "...", "winner": "A" | "B" | "tie", "reason": "..."}`.
3. Score it: `python3 eval.py --verdicts eval-verdicts.jsonl` (merges into `eval-results.jsonl` and prints the summary; no API calls).

Notes:
- The baseline is what the app produced at the time, so a run compares *new config* vs *logged config*.
- Positions are shuffled per trace so the judge's A/B bias cancels out; `--seed` makes runs repeatable.
- Only `completed` traces are replayed unless you pass `--all-outcomes`.
- Any OpenAI-compatible endpoint works: `--base-url http://localhost:11434/v1 --api-key-env OLLAMA_KEY`. Model ids must exist on that endpoint, so pass `--model` when the logged one came from another provider.
- Sidecast latency in the app is non-streaming (`firstTokenMs` is empty); the replay always streams.

Tests: `python3 -m unittest test_eval`
