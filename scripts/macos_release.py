#!/usr/bin/env python3
"""Release metadata and appcast publication. Uses only the Python standard library."""

import argparse
import base64
import copy
import hashlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
PREVIEW_TAG = "preview"
TEMPORARY_APPCAST_LABEL = "Temporary appcast from "
ET.register_namespace("sparkle", SPARKLE)
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?(?:rc([1-9][0-9]*))?")


def version_info(value):
    version = value.removeprefix("v")
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError(f"Invalid release version: {value}; expected vMAJOR.MINOR[.PATCH][rcN]")
    major, minor, patch, candidate = match.groups()
    key = (int(major), int(minor), int(patch or 0), candidate is None, int(candidate or 0))
    return version, version.split("rc")[0], "rc" if candidate else "stable", key


def validate_release(release):
    tag = release["tag_name"]
    if not tag.startswith("v"):
        raise ValueError(f"Release tag must start with v: {tag}")
    info = version_info(tag)
    if release.get("draft") or release.get("prerelease") != (info[2] == "rc"):
        raise ValueError(f"{tag}: release must be published and prerelease must match the rc suffix")
    return info


def sparkle(name):
    return f"{{{SPARKLE}}}{name}"


def parse_item(data, tag, repository):
    """Validate one per-release feed before incorporating it into the preview feed."""
    version, _, channel, _ = version_info(tag)
    root = ET.fromstring(data)
    items = root.findall("./channel/item") if root.tag == "rss" else []
    if len(items) != 1:
        raise ValueError(f"{tag}: expected exactly one release item")
    item = items[0]
    if item.findtext(sparkle("shortVersionString")) != version:
        raise ValueError(f"{tag}: appcast display version does not match tag")
    expected_channel = "rc" if channel == "rc" else None
    if item.findtext(sparkle("channel")) != expected_channel:
        raise ValueError(f"{tag}: incorrect Sparkle channel")
    build = item.findtext(sparkle("version"), "")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError(f"{tag}: invalid build number")
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise ValueError(f"{tag}: expected one enclosure")
    enclosure = enclosures[0]
    prefix = f"https://github.com/{repository}/releases/download/{tag}/Nativ-{version}"
    if enclosure.get("url") not in (prefix + ".dmg", prefix + ".zip"):
        raise ValueError(f"{tag}: incorrect download URL")
    signature = enclosure.get(sparkle("edSignature"), "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError(f"{tag}: invalid EdDSA signature metadata")
    if not re.fullmatch(r"[1-9][0-9]*", enclosure.get("length", "")):
        raise ValueError(f"{tag}: invalid archive length")
    return item


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        name = temporary.name
        temporary.write(data)
    try:
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def finalize_appcast(path, tag, repository):
    """Enclosure signatures authenticate archive bytes, not the editable XML metadata.

    Do not use this with SURequireSignedAppcast: feed-level signing would need to
    happen *after* editing/merging the XML.
    """
    data = Path(path).read_bytes()
    if b"<!-- sparkle-signatures:" in data:
        raise ValueError("Cannot edit a feed-level signed appcast; sign after editing instead")
    root = ET.fromstring(data)
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Expected one generated appcast item")
    version, _, _, _ = version_info(tag)
    item = items[0]
    item.find(sparkle("shortVersionString")).text = version
    item.find("title").text = version
    result = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    parse_item(result, tag, repository)
    atomic_write(path, result)


class GitHub:
    def __init__(self, repository):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("Invalid GitHub repository")
        self.repository = repository

    def request(self, url, *, api=False, head=False):
        headers = {"User-Agent": "Nativ-release-publisher"}
        if api:
            headers["Accept"] = "application/vnd.github+json"
            token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
            if token:
                headers["Authorization"] = f"Bearer {token}"
        for attempt in range(3):
            try:
                request = urllib.request.Request(url, headers=headers, method="HEAD" if head else "GET")
                with urllib.request.urlopen(request, timeout=60) as response:
                    return response.headers if head else response.read()
            except (urllib.error.URLError, TimeoutError):
                if attempt == 2:
                    raise
                time.sleep(2 ** attempt)

    def releases(self):
        releases = []
        page = 1
        while True:
            data = self.request(
                f"https://api.github.com/repos/{self.repository}/releases?per_page=100&page={page}", api=True
            )
            batch = json.loads(data)
            releases.extend(batch)
            if len(batch) < 100:
                return releases
            page += 1

    def release(self, tag):
        if tag != PREVIEW_TAG:
            version_info(tag)  # Validate before putting the tag in a URL.
        return json.loads(self.request(
            f"https://api.github.com/repos/{self.repository}/releases/tags/{tag}", api=True
        ))

    def mutate(self, method, path, payload=None, *, upload=False):
        """Do not retry writes blindly: an interrupted response may have committed."""
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if not token:
            raise ValueError("Publishing requires GH_TOKEN or GITHUB_TOKEN with contents:write")
        host = "uploads.github.com" if upload else "api.github.com"
        url = f"https://{host}/repos/{self.repository}/{path}"
        data = payload if upload else (json.dumps(payload).encode() if payload is not None else None)
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "Content-Type": "application/xml" if upload else "application/json",
            "User-Agent": "Nativ-release-publisher",
        })
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read()
            return json.loads(body) if body else None

    def create_preview(self):
        return self.mutate("POST", "releases", {
            "tag_name": PREVIEW_TAG, "target_commitish": "main",
            "name": "Preview update channel", "prerelease": True, "make_latest": "false",
            "body": "Rolling update feed for Nativ’s opt-in Release Candidates channel. "
                    "Download applications from the versioned releases. This release contains only update metadata.",
        })

    def upload_appcast_asset(self, release_id, name, data, *, label=None):
        parameters = {"name": name}
        if label is not None:
            parameters["label"] = label
        return self.mutate("POST", f"releases/{release_id}/assets?{urllib.parse.urlencode(parameters)}",
                           data, upload=True)

    def rename_asset(self, asset_id, name):
        return self.mutate("PATCH", f"releases/assets/{asset_id}", {"name": name})

    def delete_asset(self, asset_id):
        self.mutate("DELETE", f"releases/assets/{asset_id}")


def is_temporary_appcast(asset):
    return bool(asset and (asset.get("label") or "").startswith(TEMPORARY_APPCAST_LABEL))


def release_items(github, releases, *, check_downloads=False):
    result = []
    for release in releases:
        if release.get("draft") or release.get("tag_name") == PREVIEW_TAG:
            continue
        assets = {asset["name"]: asset for asset in release.get("assets", [])}
        # Published releases exist before the macOS build completes. Never expose
        # these until the final appcast and archive are both available. A copied
        # feed keeps stable updates working, but still describes an older release.
        if "appcast.xml" not in assets or is_temporary_appcast(assets["appcast.xml"]):
            continue
        version, _, _, key = validate_release(release)
        tag = release["tag_name"]
        archive = assets.get(f"Nativ-{version}.dmg")
        if not archive or archive.get("state") != "uploaded":
            raise ValueError(f"{tag}: appcast exists without a completely uploaded archive")
        url = f"https://github.com/{github.repository}/releases/download/{tag}/appcast.xml"
        item = parse_item(github.request(url), tag, github.repository)
        enclosure = item.find("enclosure")
        if int(enclosure.get("length")) != archive["size"]:
            raise ValueError(f"{tag}: archive length differs from signed appcast")
        if check_downloads:
            github.request(enclosure.get("url"), head=True)
        result.append((key, int(item.findtext(sparkle("version"))), item))
    return result


def preview_appcast(records):
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Nativ — Stable and Release Candidates"
    # Preserve compatible older releases for Sparkle's OS/hardware filtering.
    # Sort by public version so a rebuilt backport never becomes the newest RC.
    builds = {}
    for key, build, item in sorted(records, key=lambda record: record[:2], reverse=True):
        if build in builds and builds[build] != key:
            raise ValueError("Distinct releases must not share a Sparkle build number")
        builds[build] = key
        channel.append(copy.deepcopy(item))
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def validate_preview_release(preview):
    if preview.get("tag_name") != PREVIEW_TAG or preview.get("prerelease") is not True or preview.get("draft"):
        raise ValueError("The preview release must be a published prerelease; it must never be marked latest/stable")
    if preview.get("immutable"):
        raise ValueError("The preview release is immutable; the rolling feed requires a mutable release")
    return {asset["name"]: asset for asset in preview.get("assets", [])}


def verify_appcast_download(github, tag, name, data):
    # A content-specific query avoids a cached redirect to the previous asset ID.
    digest = hashlib.sha256(data).hexdigest()
    url = f"https://github.com/{github.repository}/releases/download/{tag}/{name}?sha256={digest}"
    for attempt in range(6):
        try:
            if github.request(url) == data:
                return
        except (urllib.error.URLError, OSError):
            if attempt == 5:
                raise
        if attempt < 5:
            time.sleep(2)
    raise ValueError(f"{tag}: published asset does not match the validated feed: {name}")


def publish_preview(github, output_path):
    # Reconstruct from versioned releases instead of editing the previous rolling
    # feed. This handles final releases, retractions, and publication retries.
    records = release_items(github, github.releases(), check_downloads=True)
    if not records:
        raise ValueError("No completed macOS releases are available for the preview feed")
    data = preview_appcast(records)
    atomic_write(output_path, data)
    try:
        preview = github.release(PREVIEW_TAG)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        preview = github.create_preview()
    validate_preview_release(preview)
    replace_appcast(github, preview, data)
    print(f"Published {len(records)} releases to "
          f"https://github.com/{github.repository}/releases/download/{PREVIEW_TAG}/appcast.xml")


def replace_appcast(github, target, data):
    """Stage and verify a feed before swapping it with a replaceable appcast."""
    tag = target["tag_name"]
    assets = {asset["name"]: asset for asset in target.get("assets", [])}
    current = assets.get("appcast.xml")
    backup = assets.get("appcast-previous.xml")
    # Recover an interrupted rename before attempting another publication.
    if current is None and backup is not None:
        current = github.rename_asset(backup["id"], "appcast.xml")
        backup = None
    if current is not None:
        url = f"https://github.com/{github.repository}/releases/download/{tag}/appcast.xml?asset={current['id']}"
        if github.request(url) == data:
            print(f"{tag}: appcast is already current")
            return

    staged_name = f"appcast-staged-{hashlib.sha256(data).hexdigest()}.xml"
    staged = assets.get(staged_name)
    if staged is not None and staged.get("state") != "uploaded":
        github.delete_asset(staged["id"])
        staged = None
    if staged is None:
        staged = github.upload_appcast_asset(target["id"], staged_name, data)
    verify_appcast_download(github, tag, staged_name, data)

    # GitHub has no atomic asset replacement. Upload/verify first, keep the old
    # asset as a backup, and restore it if promoting the new feed fails.
    try:
        if current is not None:
            if backup is not None:
                github.delete_asset(backup["id"])
            github.rename_asset(current["id"], "appcast-previous.xml")
        github.rename_asset(staged["id"], "appcast.xml")
        verify_appcast_download(github, tag, "appcast.xml", data)
    except Exception as publish_error:
        try:
            remaining = {asset["name"]: asset for asset in github.release(tag).get("assets", [])}
            live = remaining.get("appcast.xml")
            if live is not None and live["id"] == staged["id"]:
                github.rename_asset(staged["id"], staged_name)
            previous = remaining.get("appcast-previous.xml")
            if current is not None and previous is not None and previous["id"] == current["id"]:
                github.rename_asset(current["id"], "appcast.xml")
        except Exception as recovery_error:
            raise RuntimeError(f"{tag}: appcast publication and recovery failed; "
                               f"recover appcast-previous.xml before retrying: {recovery_error}") from publish_error
        raise


def seed_appcast(github, tag):
    target = github.release(tag)
    _, _, channel, key = validate_release(target)
    if channel != "stable":
        return  # RC releases use the fixed preview feed, not releases/latest.
    assets = {asset["name"]: asset for asset in target.get("assets", [])}
    current = assets.get("appcast.xml")
    if current is not None and (not is_temporary_appcast(current) or current.get("state") == "uploaded"):
        print(f"{tag}: appcast is already attached")
        return
    if target.get("immutable"):
        raise ValueError(f"{tag}: cannot attach an appcast to an immutable release")
    if current is not None:
        github.delete_asset(current["id"])  # Retry an incomplete placeholder upload.
    backup = assets.get("appcast-previous.xml")
    if is_temporary_appcast(backup):
        github.rename_asset(backup["id"], "appcast.xml")
        return
    candidates = []
    for previous in github.releases():
        if previous.get("draft") or previous.get("prerelease") or previous["tag_name"] == PREVIEW_TAG:
            continue
        appcast = next((asset for asset in previous.get("assets", []) if asset["name"] == "appcast.xml"), None)
        if appcast is None or is_temporary_appcast(appcast):
            continue
        previous_key = validate_release(previous)[3]
        if previous_key < key:
            candidates.append((previous_key, previous))
    if not candidates:
        print(f"{tag}: no previous stable macOS appcast to attach")
        return
    # Only download the selected feed so startup does not wait on every release.
    _, previous = max(candidates, key=lambda candidate: candidate[0])
    release_items(github, [previous], check_downloads=True)
    source_tag = previous["tag_name"]
    data = github.request(f"https://github.com/{github.repository}/releases/download/{source_tag}/appcast.xml")
    parse_item(data, source_tag, github.repository)
    github.upload_appcast_asset(target["id"], "appcast.xml", data,
                                label=TEMPORARY_APPCAST_LABEL + source_tag)
    verify_appcast_download(github, tag, "appcast.xml", data)
    print(f"{tag}: attached the {source_tag} appcast until the new build is ready")


def publish_release_appcast(github, tag, path):
    target = github.release(tag)
    version, _, _, _ = validate_release(target)
    if target.get("immutable"):
        raise ValueError(f"{tag}: cannot publish an appcast to an immutable release")
    data = Path(path).read_bytes()
    item = parse_item(data, tag, github.repository)
    assets = {asset["name"]: asset for asset in target.get("assets", [])}
    archive = assets.get(f"Nativ-{version}.dmg")
    enclosure = item.find("enclosure")
    if (not archive or archive.get("state") != "uploaded"
            or archive["size"] != int(enclosure.get("length"))):
        raise ValueError(f"{tag}: upload the matching DMG before publishing its appcast")
    github.request(enclosure.get("url"), head=True)
    current = assets.get("appcast.xml")
    if current is not None and not is_temporary_appcast(current):
        url = f"https://github.com/{github.repository}/releases/download/{tag}/appcast.xml?asset={current['id']}"
        if github.request(url) == data:
            print(f"{tag}: appcast is already current")
            return
        raise ValueError(f"{tag}: refusing to replace a completed release appcast")
    backup = assets.get("appcast-previous.xml")
    if backup is not None and not is_temporary_appcast(backup):
        raise ValueError(f"{tag}: refusing to replace an unrecognized appcast backup")
    replace_appcast(github, target, data)
    print(f"{tag}: published the new release appcast")


def preflight(github, tag, environment_path, notes_path):
    release = github.release(tag)
    version, _, channel, key = validate_release(release)
    if any(asset["name"] == f"Nativ-{version}.dmg"
           or (asset["name"] == "appcast.xml" and not is_temporary_appcast(asset))
           for asset in release.get("assets", [])):
        raise ValueError(f"{tag}: release assets already exist; publish a new version instead of replacing signed downloads")
    records = release_items(github, github.releases())
    if channel == "rc" and any(record[0] >= key for record in records):
        raise ValueError(f"{tag}: release candidates must advance beyond every published release")
    # Retain the existing timestamp scheme, while avoiding collisions and making
    # every newly published build newer than every existing stable/RC build.
    clock_build = int(datetime.now(timezone.utc).strftime("%Y%m%d%H%M"))
    build = max([clock_build - 1] + [record[1] for record in records]) + 1
    with Path(environment_path).open("a") as environment:
        environment.write(f"RELEASE_VERSION={version}\nRELEASE_CHANNEL={channel}\nRELEASE_BUILD_NUMBER={build}\n")
    Path(notes_path).write_text(release.get("body") or "", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    version = commands.add_parser("version")
    version.add_argument("value")
    finalize = commands.add_parser("finalize-appcast")
    finalize.add_argument("path")
    finalize.add_argument("--tag", required=True)
    finalize.add_argument("--repository", required=True)
    prepare = commands.add_parser("preflight")
    prepare.add_argument("--tag", required=True)
    prepare.add_argument("--repository", required=True)
    prepare.add_argument("--environment", required=True)
    prepare.add_argument("--notes", required=True)
    validate = commands.add_parser("validate-release")
    validate.add_argument("--tag", required=True)
    validate.add_argument("--repository", required=True)
    seed = commands.add_parser("seed-appcast", help="Temporarily attach the previous stable feed during a build")
    seed.add_argument("--tag", required=True)
    seed.add_argument("--repository", required=True)
    publish_release = commands.add_parser("publish-appcast", help="Replace a temporary feed after uploading the DMG")
    publish_release.add_argument("--tag", required=True)
    publish_release.add_argument("--repository", required=True)
    publish_release.add_argument("--path", default="dist/release/appcast.xml")
    preview = commands.add_parser("preview")
    preview.add_argument("--repository", required=True)
    preview.add_argument("--output", required=True)
    publish = commands.add_parser("publish-preview", help="Refresh the fixed preview release; requires contents:write")
    publish.add_argument("--repository", required=True)
    publish.add_argument("--output", default="dist/release/preview-appcast.xml")
    args = parser.parse_args()
    if args.command == "version":
        full, marketing, channel, _ = version_info(args.value)
        print(full, marketing, channel, "v" + full)
    elif args.command == "finalize-appcast":
        finalize_appcast(args.path, args.tag, args.repository)
    elif args.command == "preflight":
        preflight(GitHub(args.repository), args.tag, args.environment, args.notes)
    elif args.command == "validate-release":
        validate_release(GitHub(args.repository).release(args.tag))
    elif args.command == "seed-appcast":
        seed_appcast(GitHub(args.repository), args.tag)
    elif args.command == "publish-appcast":
        publish_release_appcast(GitHub(args.repository), args.tag, args.path)
    elif args.command == "publish-preview":
        publish_preview(GitHub(args.repository), args.output)
    else:
        github = GitHub(args.repository)
        records = release_items(github, github.releases(), check_downloads=True)
        # This command only generates a local feed; publish-preview uploads it.
        atomic_write(args.output, preview_appcast(records))
        print(f"Validated preview appcast with {len(records)} releases: {args.output}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, RuntimeError, ET.ParseError, urllib.error.URLError, OSError) as error:
        sys.exit(f"error: {error}")
