"""Publish only a reviewed, hash-bound source tree; never execute patched code."""
import base64
import hashlib
import json
import lzma
import os
from pathlib import Path
import subprocess
import urllib.request

REPO = "seichris/open-bike-computer"
BASE = "c7ddf14df7fb56bcdaf184ae29d10f3ff84a0e38"
BASE_TREE = "aab73c34ecf8d2ae0151cb27e9fa1a143bbc8c91"
RESULT_TREE = "17e64219d9454ffefed44001681b6f15299dce96"
PATCH_SHA = "07df59ab35d9883820b9062a97c6506eb0b6fc47b25c02b50ead69ea09497c0a"
assert os.environ["GITHUB_REPOSITORY"] == REPO
assert os.environ["GITHUB_REF"] == "refs/heads/implement/wifi-device-operation-lifecycle"

def git(*args, data=None):
    return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *args], input=data)

staging = git("rev-parse", "HEAD").decode().strip()
assert git("rev-parse", "HEAD^").decode().strip() == BASE
assert git("rev-parse", "HEAD^^{tree}").decode().strip() == BASE_TREE
encoded = b"".join(Path(f".github/diagnostics-reviewed/part-{i}.txt").read_bytes() for i in range(8))
assert len(encoded) == 87880
compressed = base64.b64decode(encoded, validate=True)
decoder = lzma.LZMADecompressor(memlimit=128 * 1024 * 1024)
patch = decoder.decompress(compressed, max_length=1024 * 1024)
assert decoder.eof and not decoder.unused_data
assert len(patch) == 342690 and hashlib.sha256(patch).hexdigest() == PATCH_SHA
# The executing script is already loaded; checkout removes every staging-only file.
git("checkout", "--detach", BASE)
git("apply", "--index", "--binary", "--whitespace=error-all", "-", data=patch)
assert git("write-tree").decode().strip() == RESULT_TREE
assert not Path(".github/diagnostics-reviewed").exists()
assert not Path(".github/workflows/diagnostics-source-snapshot.yml").exists()

def api(path, value):
    request = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/{path}",
        data=json.dumps(value).encode(),
        headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"],
                 "Accept": "application/vnd.github+json", "Content-Type": "application/json",
                 "X-GitHub-Api-Version": "2022-11-28"}, method="POST")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)

entries = []
for raw in git("diff", "--cached", "--name-only", "-z", BASE).split(b"\0"):
    if not raw:
        continue
    path = raw.decode()
    assert not path.startswith("/") and ".." not in path.split("/")
    row = git("ls-files", "--stage", "--", path).decode().strip()
    if not row:
        entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
        continue
    mode, expected, stage = row.split("\t")[0].split()
    assert mode in {"100644", "100755"} and stage == "0"
    payload = git("show", ":" + path)
    assert len(payload) < 2 * 1024 * 1024
    blob = api("git/blobs", {"content": base64.b64encode(payload).decode(), "encoding": "base64"})
    assert blob["sha"] == expected
    entries.append({"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]})
result = api("git/trees", {"base_tree": BASE_TREE, "tree": entries})
assert result["sha"] == RESULT_TREE
commit = api("git/commits", {
    "message": "Implement bounded agent diagnostics and durable post-ride collection",
    "tree": RESULT_TREE, "parents": [staging]})
# No ref write here. The authorized connector advances the branch and triggers CI.
publication = {"commit": commit["sha"], "parent": staging, "tree": RESULT_TREE,
               "base": BASE, "patchSha256": PATCH_SHA, "changedFiles": len(entries)}
Path(os.environ["RUNNER_TEMP"], "publication.json").write_text(json.dumps(publication, indent=2) + "\n")
print(json.dumps(publication))
