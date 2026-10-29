"""Check one headless run against calls.json.

usage: check.py <guard|control|mutant> <run.jsonl> <calls.json> <vars.json>

Exit 0: every call ran once or more and got its expected result.
Exit 1: a call got the wrong result. Never retried: this is the failure the test exists for.
Exit 3: the run is incomplete (a call is missing, or the model made a call that is not in
the list) and nothing got a wrong result. The caller may run it again once.
A skipped call is never a pass: exit 3, and exit 1 if a second run skips it too.
"""
import json
import os
import sys

mode, run_file, calls_file, vars_file = sys.argv[1:]
spec = json.load(open(calls_file))
names = json.load(open(vars_file))
ARG_KEYS = {"Read": "file_path", "Write": "file_path", "Grep": "path", "Glob": "path", "Bash": "command"}


def norm(tool, arg):
    return arg if tool == "Bash" else os.path.normpath(arg)


uses, results, final, init = [], {}, None, None
for line in open(run_file):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    kind = event.get("type")
    content = event["message"].get("content") if kind in ("assistant", "user") else None
    if kind == "system" and event.get("subtype") == "init":
        init = event
    elif kind == "assistant":
        uses += [c for c in content or [] if c.get("type") == "tool_use"]
    elif kind == "user" and isinstance(content, list):
        for c in content:
            if c.get("type") == "tool_result":
                text = c.get("content")
                results[c["tool_use_id"]] = (bool(c.get("is_error")), text if isinstance(text, str) else json.dumps(text))
    elif kind == "result":
        final = event

if final is None or init is None:
    print(f"::error::{mode}: the run has no init or no result event")
    sys.exit(3)
wrong, unstable = [], []
denied = {d["tool_use_id"] for d in final.get("permission_denials", [])}
tools = sorted(init.get("tools", []))
if mode != "control" and tools != sorted(spec["tools"]):
    wrong.append(f"the CLI offers tools {tools}, expected {sorted(spec['tools'])}: deny any new tool")

matched = set()
for n, call in enumerate(spec["calls"], 1):
    arg = norm(call["tool"], call["arg"].format(**names))
    want = call["guard"] if mode == "guard" else call["control"] if mode == "control" else ("allow" if call.get("mutant") else call["guard"])
    hits = [u for u in uses if u["name"] == call["tool"] and norm(call["tool"], str(u["input"].get(ARG_KEYS[call["tool"]], ""))) == arg]
    matched.update(u["id"] for u in hits)
    if not hits:
        unstable.append(f"call {n} ({call['tool']} {call['arg']}) was never made")
        continue
    for u in hits:
        is_error, text = results.get(u["id"], (True, "no tool result"))
        got = "deny" if u["id"] in denied else "error" if is_error else "allow"
        ok = want == "any" or got == want
        print(f"{'ok ' if ok else 'BAD'} {n:2} {call['tool']:5} {call['arg']:28} want {want:5} got {got}")
        if not ok:
            wrong.append(f"call {n} ({call['tool']} {call['arg']}): expected {want}, got {got}: {text[:200]}")
for u in uses:
    if u["id"] not in matched:
        unstable.append(f"the model made an unlisted call: {u['name']} {json.dumps(u['input'])[:200]}")

if mode == "guard":
    # Nothing a denied call protects may reach the model by any route.
    for u in uses:
        if "FAKE-" in results.get(u["id"], (False, ""))[1]:
            wrong.append(f"a fake secret reached the model through {u['name']} {json.dumps(u['input'])[:200]}")

print(f"{mode}: {len(uses)} calls, {len(denied)} denials, cost ${final.get('total_cost_usd', 0):.4f}")
for msg in wrong + unstable:
    print(f"::error::{mode}: {msg}")
sys.exit(1 if wrong else 3 if unstable else 0)
