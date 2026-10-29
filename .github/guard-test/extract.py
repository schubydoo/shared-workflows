"""Write the review workflow's tested pieces out as plain files.

usage: extract.py <workflow.yml> <out-dir>

Writes resolve.sh (the resolve step), pincheck.sh (the pin check), allowed-tools.txt
(the --allowedTools value of the action's claude_args, one tool per line), and api-tools.txt
and api-allowed.txt (the --tools and --allowedTools values of the api path's `claude -p`).
"""
import re
import sys

import yaml

workflow, out = sys.argv[1], sys.argv[2]
steps = yaml.safe_load(open(workflow))["jobs"]["review"]["steps"]


def step(**match):
    found = [s for s in steps if all(s.get(k) == v for k, v in match.items())]
    if len(found) != 1:
        sys.exit(f"extract.py: expected one step with {match}, found {len(found)}")
    return found[0]


open(f"{out}/resolve.sh", "w").write(step(id="resolve")["run"])
open(f"{out}/pincheck.sh", "w").write(step(name="Check the review covered the pinned commit")["run"])
args = step(id="review")["with"]["claude_args"]
tools = re.findall(r'--allowedTools "([^"]*)"', args)
if len(tools) != 1:
    sys.exit(f"extract.py: expected one --allowedTools in claude_args, found {len(tools)}")
open(f"{out}/allowed-tools.txt", "w").write("\n".join(tools[0].split(",")) + "\n")

# headless.sh passes the api path's other flags as written here. If the step changes them,
# this fails, so the test cannot drift from the step.
api = step(id="review-api")["run"]
for flag in ("--permission-mode acceptEdits", "--setting-sources user", "--strict-mcp-config",
             '--settings "$SETTINGS"', "--add-dir pr-head", '--add-dir "$RULES_DIR"',
             '--add-dir "$PAYLOAD"', '--disallowedTools "$DENY"'):
    if api.count(flag) != 1:
        sys.exit(f"extract.py: the review-api step no longer passes {flag} once: update headless.sh")
for name, flag in (("api-tools", "--tools"), ("api-allowed", "--allowedTools")):
    found = re.findall(rf'{flag} "([^"]*)"', api)
    if len(found) != 1:
        sys.exit(f"extract.py: expected one {flag} in the review-api step, found {len(found)}")
    open(f"{out}/{name}.txt", "w").write(found[0] + "\n")
