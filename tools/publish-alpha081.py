#!/usr/bin/env python3
"""Publish the exact independently audited candidate; never rebuild release bytes."""
import hashlib
import io
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLAN = json.loads((ROOT / "release/alpha081-publish.json").read_text())
REPO = "rewinddv/rewindDV-LAB"
BASE = "https://api.github.com/repos/" + REPO
TOKEN = os.environ["GH_TOKEN"]
HEAD = os.environ["GITHUB_SHA"]
assert os.environ["GITHUB_REPOSITORY"] == REPO


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(path, method="GET", payload=None, raw=None, content_type=None):
    url = path if path.startswith("https://") else BASE + path
    assert urllib.parse.urlsplit(url).hostname in {"api.github.com", "uploads.github.com"}
    headers = {"Authorization": "Bearer " + TOKEN,
               "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28",
               "User-Agent": "rewindDV-release-automation"}
    data = raw
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, headers=headers, method=method, data=data)
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=90) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 302 and method == "GET":
            # GitHub download redirects are signed. Never forward the API token.
            location = error.headers["Location"]
            assert urllib.parse.urlsplit(location).scheme == "https"
            with urllib.request.urlopen(location, timeout=90) as response:
                return response.read()
        raise


def api(path, method="GET", payload=None):
    return json.loads(request(path, method, payload))


def optional(path):
    try:
        return api(path)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def digest(data):
    return hashlib.sha256(data).hexdigest()


run = api("/actions/runs/" + str(PLAN["run_id"]))
assert run["conclusion"] == "success" and run["head_sha"] == PLAN["candidate_tooling_sha"]
artifact = api("/actions/artifacts/" + str(PLAN["artifact_id"]))
assert not artifact["expired"] and artifact["workflow_run"]["id"] == PLAN["run_id"]
archive = request("/actions/artifacts/" + str(PLAN["artifact_id"]) + "/zip")
assert digest(archive) == PLAN["artifact_sha256"], "Candidate artifact archive differs"
name = "rewindDV-Alpha-0.0.81-Build183-AdHoc.zip"
with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
    assert set(bundle.namelist()) == {name, name + ".sha256", "candidate-seal.json", "bundle-tree-manifest.json"}
    assert bundle.testzip() is None
    package = bundle.read(name)
    sidecar = bundle.read(name + ".sha256")
    seal = json.loads(bundle.read("candidate-seal.json"))
assert digest(package) == PLAN["zip_sha256"] == seal["sha256"]
assert sidecar.decode().split() == [PLAN["zip_sha256"], name]
assert seal["source_commit"] == PLAN["source_sha"] and seal["driver_tree_unchanged"]
assert seal["dext_sha256"] == PLAN["dext_sha256"]
notes_bytes = (ROOT / "release/alpha081-published-notes.md").read_bytes()
assert digest(notes_bytes) == PLAN["notes_sha256"]
notes = notes_bytes.decode()
tag_name = "alpha-0.0.81"
tag_ref = optional("/git/ref/tags/" + tag_name)
if tag_ref is None:
    tag = api("/git/tags", "POST", {
        "tag": tag_name, "message": "Alpha 0.0.81 / unchanged Driver Build183",
        "object": HEAD, "type": "commit",
        "tagger": {"name": "rewindDV", "email": "git@rewinddv.com"}})
    tag_ref = api("/git/refs", "POST", {"ref": "refs/tags/" + tag_name, "sha": tag["sha"]})
assert tag_ref["object"]["type"] == "tag"
tag = api("/git/tags/" + tag_ref["object"]["sha"])
assert tag["object"] == {"sha": HEAD, "type": "commit", "url": BASE + "/git/commits/" + HEAD}
assert tag["tagger"]["name"] == "rewindDV" and tag["tagger"]["email"] == "git@rewinddv.com"
release = optional("/releases/tags/" + tag_name)
if release is None:
    release = api("/releases", "POST", {
        "tag_name": tag_name, "target_commitish": HEAD,
        "name": "Alpha 0.0.81 · Driver B183 — engineering alpha",
        "body": notes, "draft": True, "prerelease": True,
        "make_latest": "false"})
assert release["author"]["login"] == "github-actions[bot]"
assert release["body"] == notes and release["prerelease"]
assets = {a["name"]: a for a in api("/releases/" + str(release["id"]) + "/assets")}
assert set(assets) <= {name, name + ".sha256"}
for filename, data, kind in [(name, package, "application/zip"), (name + ".sha256", sidecar, "text/plain")]:
    asset = assets.get(filename)
    if asset is None:
        assert release["draft"], "Never change an already published artifact"
        url = release["upload_url"].split("{")[0] + "?name=" + urllib.parse.quote(filename)
        asset = json.loads(request(url, "POST", raw=data, content_type=kind))
    assert asset["state"] == "uploaded" and asset["size"] == len(data)
    assert asset["uploader"]["login"] == "github-actions[bot]"
    assert asset["digest"] == "sha256:" + digest(data)
if release["draft"]:
    release = api("/releases/" + str(release["id"]), "PATCH", {"draft": False, "prerelease": True, "make_latest": "false"})
previous = api("/releases/tags/alpha-0.0.77")
notice = "Superseded by [Alpha 0.0.81 / Driver Build183](https://github.com/rewinddv/rewindDV-LAB/releases/tag/alpha-0.0.81). Retained here as a historical release."
if notice not in previous["body"]:
    api("/releases/" + str(previous["id"]), "PATCH", {"body": notice + "\n\n" + previous["body"]})
print(json.dumps({"release_id": release["id"], "url": release["html_url"], "zip_sha256": digest(package), "source_sha": PLAN["source_sha"], "tag_commit": HEAD}))
