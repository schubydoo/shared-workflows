"""Write the review workflow's tested pieces out as plain files.

usage: extract.py <workflow.yml> <out-dir>

Writes resolve.sh (the resolve step), pincheck.sh (the pin check) and allowed-tools.txt
(the --allowedTools value of the action's claude_args, one tool per line).
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
