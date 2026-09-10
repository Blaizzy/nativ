import base64
import copy
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import urllib.error
import urllib.parse
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile


spec = importlib.util.spec_from_file_location("macos_release", Path(__file__).parents[1] / "macos_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
REPOSITORY = "Blaizzy/nativ"
SIGNATURE = base64.b64encode(bytes(64)).decode()


def feed(version="0.4.0rc1", build=200, channel="rc"):
    root = ET.Element("rss", version="2.0")
    item = ET.SubElement(ET.SubElement(root, "channel"), "item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, release.sparkle("version")).text = str(build)
    ET.SubElement(item, release.sparkle("shortVersionString")).text = version
    if channel is not None:
        ET.SubElement(item, release.sparkle("channel")).text = channel
    ET.SubElement(item, release.sparkle("minimumSystemVersion")).text = "26.0"
    ET.SubElement(item, "description").text = "<p>Release notes & details</p>"
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{REPOSITORY}/releases/download/v{version}/Nativ-{version}.dmg",
        "length": "1234", release.sparkle("edSignature"): SIGNATURE,
    })
    return ET.tostring(root)


def metadata(version="0.4.0rc1"):
    return {
        "tag_name": "v" + version, "prerelease": "rc" in version, "draft": False,
        "body": "Notes", "assets": [
            {"name": "appcast.xml", "state": "uploaded", "size": 100},
            {"name": f"Nativ-{version}.dmg", "state": "uploaded", "size": 1234},
        ],
    }


class FakeGitHub:
    repository = REPOSITORY

    def __init__(self, releases, feeds):
        self.data = releases
        self.feeds = feeds

    def release(self, tag):
        return next(item for item in self.data if item["tag_name"] == tag)

    def releases(self):
        return self.data

    def request(self, url, *, head=False):
        if head:
            return {}
        return self.feeds[url.split("/")[-2]]


class ReleaseTests(unittest.TestCase):
    def test_versions_and_numeric_candidate_order(self):
        versions = ["v0.3.9", "v0.4.0rc1", "v0.4.0rc2", "v0.4.0rc10", "v0.4.0", "v0.4.1rc1"]
        self.assertEqual(sorted(reversed(versions), key=lambda value: release.version_info(value)[3]), versions)
        self.assertEqual(release.version_info("v0.4.0rc1")[:3], ("0.4.0rc1", "0.4.0", "rc"))
        self.assertEqual(release.version_info("0.4")[3], release.version_info("0.4.0")[3])

    def test_invalid_versions(self):
        for invalid in ["0.4.0rc0", "0.4.0rc01", "0.4.0-rc1", "0.4.0beta1", "0.4.0\n", "01.4.0", "", "v0.4.0;echo bad"]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                release.version_info(invalid)

    def test_release_flags_must_match_tag(self):
        for version in ["0.4.0", "0.4.0rc1"]:
            data = metadata(version)
            release.validate_release(data)
            data["prerelease"] = not data["prerelease"]
            with self.assertRaises(ValueError):
                release.validate_release(data)
        data = metadata()
        data["draft"] = True
        with self.assertRaises(ValueError):
            release.validate_release(data)

    def test_signed_item_validation(self):
        item = release.parse_item(feed(), "v0.4.0rc1", REPOSITORY)
        self.assertEqual(item.find("enclosure").get(release.sparkle("edSignature")), SIGNATURE)
        release.parse_item(feed("0.4.0", channel=None), "v0.4.0", REPOSITORY)

    def test_bad_channel_or_tag_is_rejected(self):
        for xml, tag in [(feed(channel=None), "v0.4.0rc1"), (feed(channel="nightly"), "v0.4.0rc1"),
                         (feed("0.4.0", channel="rc"), "v0.4.0"), (feed(), "v0.4.0rc2")]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.parse_item(xml, tag, REPOSITORY)

    def test_bad_archive_metadata_is_rejected(self):
        for field, value in [("url", "https://example.com/Nativ.dmg"), ("length", "0"),
                             ("length", "-1"), (release.sparkle("edSignature"), "bad")]:
            root = ET.fromstring(feed())
            root.find("./channel/item/enclosure").set(field, value)
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.parse_item(ET.tostring(root), "v0.4.0rc1", REPOSITORY)

    def test_finalizing_numeric_bundle_version_preserves_signed_archive(self):
        root = ET.fromstring(feed())
        root.find("./channel/item/" + release.sparkle("shortVersionString")).text = "0.4.0"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_bytes(ET.tostring(root))
            release.finalize_appcast(path, "v0.4.0rc1", REPOSITORY)
            item = release.parse_item(path.read_bytes(), "v0.4.0rc1", REPOSITORY)
            self.assertEqual(item.findtext("title"), "0.4.0rc1")
            self.assertEqual(item.find("enclosure").attrib, root.find("./channel/item/enclosure").attrib)

    def test_finalizing_feed_level_signed_xml_fails_without_modifying_it(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            original = feed() + b"<!-- sparkle-signatures:\nedSignature: test\n-->"
            path.write_bytes(original)
            with self.assertRaises(ValueError):
                release.finalize_appcast(path, "v0.4.0rc1", REPOSITORY)
            self.assertEqual(path.read_bytes(), original)

    def test_preview_preserves_signatures_notes_and_compatibility_metadata(self):
        versions = [("0.3.8", 400, None), ("0.4.0rc2", 300, "rc"), ("0.4.0", 200, None)]
        records = [(release.version_info(v)[3], b, release.parse_item(feed(v, b, c), "v" + v, REPOSITORY))
                   for v, b, c in versions]
        root = ET.fromstring(release.preview_appcast(records))
        items = root.findall("./channel/item")
        self.assertEqual([i.findtext(release.sparkle("shortVersionString")) for i in items], ["0.4.0", "0.4.0rc2", "0.3.8"])
        for item in items:
            self.assertEqual(item.findtext("description"), "<p>Release notes & details</p>")
            self.assertEqual(item.findtext(release.sparkle("minimumSystemVersion")), "26.0")
            self.assertEqual(item.find("enclosure").get(release.sparkle("edSignature")), SIGNATURE)

    def test_duplicate_builds_rejected(self):
        records = [(release.version_info(v)[3], 200, release.parse_item(feed(v), "v" + v, REPOSITORY))
                   for v in ["0.4.0rc1", "0.4.0rc2"]]
        with self.assertRaises(ValueError):
            release.preview_appcast(records)

    def test_unfinished_release_is_not_advertised(self):
        incomplete = metadata("0.4.0rc2")
        incomplete["assets"] = incomplete["assets"][1:]
        github = FakeGitHub([metadata(), incomplete], {"v0.4.0rc1": feed()})
        self.assertEqual(len(release.release_items(github, github.releases())), 1)

    def test_feed_with_missing_or_wrong_size_archive_fails(self):
        data = metadata()
        data["assets"][1]["size"] = 1
        github = FakeGitHub([data], {"v0.4.0rc1": feed()})
        with self.assertRaises(ValueError):
            release.release_items(github, github.releases())
        data["assets"] = data["assets"][:1]
        with self.assertRaises(ValueError):
            release.release_items(FakeGitHub([data], {}), [data])

    def test_preflight_increases_build_number_and_preserves_full_rc_label(self):
        new = metadata("0.4.0rc2")
        new["assets"] = []
        github = FakeGitHub([metadata(), new], {"v0.4.0rc1": feed(build=999999999999)})
        with tempfile.TemporaryDirectory() as directory:
            env, notes = Path(directory) / "env", Path(directory) / "notes"
            release.preflight(github, "v0.4.0rc2", env, notes)
            self.assertIn("RELEASE_BUILD_NUMBER=1000000000000", env.read_text())
            self.assertIn("RELEASE_VERSION=0.4.0rc2", env.read_text())
            self.assertIn("RELEASE_CHANNEL=rc", env.read_text())
            self.assertEqual(notes.read_text(), "Notes")

    def test_published_downloads_cannot_be_replaced(self):
        github = FakeGitHub([metadata()], {})
        with self.assertRaisesRegex(ValueError, "already exist"):
            release.preflight(github, "v0.4.0rc1", "unused", "unused")

    def test_candidate_after_final_or_out_of_order_is_rejected(self):
        for previous, channel in [("0.4.0", None), ("0.4.0rc3", "rc")]:
            new = metadata("0.4.0rc2")
            new["assets"] = []
            github = FakeGitHub([metadata(previous), new], {"v" + previous: feed(previous, channel=channel)})
            with self.subTest(previous=previous), self.assertRaisesRegex(ValueError, "advance"):
                release.preflight(github, "v0.4.0rc2", "unused", "unused")

    def test_download_failure_prevents_feed_publication(self):
        github = FakeGitHub([metadata()], {"v0.4.0rc1": feed()})
        original_request = github.request
        def fail_download(url, *, head=False):
            if head:
                raise OSError("Archive unavailable")
            return original_request(url)
        with patch.object(github, "request", side_effect=fail_download):
            with self.assertRaises(OSError):
                release.release_items(github, github.releases(), check_downloads=True)

    @unittest.skipUnless(sys.platform == "darwin", "Uses macOS PlistBuddy and the release shell script")
    def test_appcast_shell_preserves_full_tag_and_numeric_bundle_version(self):
        # Exercise the real ZIP metadata and shell argument path. The signing
        # executable is substituted so this test never accesses a signing key.
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            generator = directory / "generate_appcast"
            generator.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import base64, pathlib, plistlib, sys, xml.etree.ElementTree as ET, zipfile
                args = sys.argv[1:]
                archive = next(pathlib.Path(args[-1]).glob("*.zip"))
                with zipfile.ZipFile(archive) as bundle:
                    info = plistlib.loads(bundle.read("Nativ.app/Contents/Info.plist"))
                ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
                ET.register_namespace("sparkle", ns)
                root = ET.Element("rss", version="2.0")
                item = ET.SubElement(ET.SubElement(root, "channel"), "item")
                ET.SubElement(item, "title").text = info["CFBundleShortVersionString"]
                ET.SubElement(item, "{" + ns + "}shortVersionString").text = info["CFBundleShortVersionString"]
                ET.SubElement(item, "{" + ns + "}version").text = info["CFBundleVersion"]
                if "--channel" in args:
                    ET.SubElement(item, "{" + ns + "}channel").text = args[args.index("--channel") + 1]
                ET.SubElement(item, "enclosure", {
                    "url": args[args.index("--download-url-prefix") + 1] + archive.name,
                    "length": str(archive.stat().st_size),
                    "{" + ns + "}edSignature": base64.b64encode(bytes(64)).decode(),
                })
                ET.ElementTree(root).write(args[args.index("-o") + 1], encoding="utf-8")
            '''))
            generator.chmod(0o755)
            environment = dict(os.environ, SPARKLE_GENERATE_APPCAST=str(generator),
                               SPARKLE_PRIVATE_KEY="test-key-not-used", NATIV_GITHUB_REPOSITORY=REPOSITORY)
            script = Path(__file__).parents[1] / "generate_macos_appcast.sh"
            for version in ["0.4.0", "0.4.0rc1"]:
                archive = directory / f"Nativ-{version}.zip"
                with zipfile.ZipFile(archive, "w") as bundle:
                    bundle.writestr("Nativ.app/Contents/Info.plist", plistlib.dumps({
                        "CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "200",
                        "NativReleaseVersion": version,
                    }))
                output = directory / "appcast.xml"
                command = ["bash", str(script), "--output", str(output), "--tag", "v" + version, str(archive)]
                result = subprocess.run(command, env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                item = release.parse_item(output.read_bytes(), "v" + version, REPOSITORY)
                self.assertEqual(item.findtext(release.sparkle("channel")), "rc" if "rc" in version else None)
                command[-2] = "v0.4.0rc999"
                mismatch = subprocess.run(command, env=environment, capture_output=True, text=True)
                self.assertNotEqual(mismatch.returncode, 0)
                self.assertIn("does not match the signed app", mismatch.stderr)


class FakePreviewGitHub(FakeGitHub):
    def __init__(self, preview=None):
        super().__init__([metadata()], {"v0.4.0rc1": feed()})
        self.preview = preview
        self.contents = {}
        self.events = []

    def releases(self):
        return self.data + ([self.preview] if self.preview else [])

    def release(self, tag):
        if tag != "preview":
            return super().release(tag)
        if self.preview is None:
            raise urllib.error.HTTPError("https://api.github.com/preview", 404, "Not found", {}, None)
        return copy.deepcopy(self.preview)

    def create_preview(self):
        self.events.append(("create",))
        self.preview = {"id": 42, "tag_name": "preview", "prerelease": True,
                        "draft": False, "immutable": False, "assets": []}
        return self.release("preview")

    def upload_preview_asset(self, release_id, name, data):
        assert release_id == 42
        asset = {"id": max(self.contents, default=0) + 1, "name": name, "state": "uploaded", "size": len(data)}
        self.preview["assets"].append(asset)
        self.contents[asset["id"]] = data
        self.events.append(("upload", name))
        return copy.deepcopy(asset)

    def rename_asset(self, asset_id, name):
        assert all(asset["name"] != name for asset in self.preview["assets"])
        asset = next(asset for asset in self.preview["assets"] if asset["id"] == asset_id)
        asset["name"] = name
        self.events.append(("rename", asset_id, name))
        return copy.deepcopy(asset)

    def delete_asset(self, asset_id):
        self.preview["assets"] = [asset for asset in self.preview["assets"] if asset["id"] != asset_id]
        self.contents.pop(asset_id)
        self.events.append(("delete", asset_id))

    def request(self, url, *, head=False):
        if "/download/preview/" not in url:
            return super().request(url, head=head)
        name = urllib.parse.urlparse(url).path.split("/")[-1]
        self.events.append(("read", name))
        return self.asset_bytes(name)

    def asset_bytes(self, name):
        asset = next(asset for asset in self.preview["assets"] if asset["name"] == name)
        return self.contents[asset["id"]]


class BumpVersionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ["bump_version.sh", "macos_release.py"]:
            shutil.copyfile(Path(__file__).parents[1] / name, scripts / name)
        self.project = self.root / "project.yml"
        self.project.write_text(textwrap.dedent("""\
            name: Nativ
            targets:
              Nativ:
                settings:
                  MARKETING_VERSION: 0.3.7
                  NATIV_RELEASE_VERSION: $(MARKETING_VERSION)
                  CURRENT_PROJECT_VERSION: 12
              Extension:
                settings:
                  MARKETING_VERSION: 0.3.7
                  CURRENT_PROJECT_VERSION: 12
            """))
        binaries = self.root / "bin"
        binaries.mkdir()
        xcodegen = binaries / "xcodegen"
        xcodegen.write_text('#!/bin/sh\n[ "$1" = generate ] || exit 1\ncp project.yml generated-project.yml\n')
        xcodegen.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"])

    def bump(self, *arguments):
        return subprocess.run(
            ["bash", str(self.root / "scripts/bump_version.sh"), *arguments],
            env=self.environment, capture_output=True, text=True,
        )

    def assert_versions(self, marketing, label, build):
        text = self.project.read_text()
        self.assertEqual(text.count(f"MARKETING_VERSION: {marketing}\n"), 2)
        self.assertEqual(text.count(f"CURRENT_PROJECT_VERSION: {build}\n"), 2)
        self.assertIn(f"NATIV_RELEASE_VERSION: {label}\n", text)
        self.assertEqual((self.root / "generated-project.yml").read_text(), text)

    def test_candidate_bumps_keep_all_bundle_versions_numeric(self):
        for version, build in [("v0.4.0rc1", 13), ("0.4.0rc2", 14)]:
            result = self.bump(version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assert_versions("0.4.0", version.removeprefix("v"), build)

    def test_stable_release_clears_candidate_label(self):
        for version in ["v0.4.0rc1", "v0.4.0"]:
            result = self.bump(version)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_versions("0.4.0", "$(MARKETING_VERSION)", 14)

    def test_default_bump_selects_next_stable_patch(self):
        result = self.bump()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_versions("0.3.8", "$(MARKETING_VERSION)", 13)
        result = self.bump("v0.4.0rc1")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.bump()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_versions("0.4.1", "$(MARKETING_VERSION)", 15)

    def test_invalid_versions_leave_project_untouched(self):
        original = self.project.read_bytes()
        for version in ["v0.4.0rc0", "v0.4.0rc01", "v0.4.0-rc1", "v0.4.0beta1", "v0.4", "v01.4.0"]:
            with self.subTest(version=version):
                result = self.bump(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.project.read_bytes(), original)
                self.assertFalse((self.root / "generated-project.yml").exists())


class PreviewPublishingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name) / "preview.xml"

    def existing_preview(self, *, backup=False):
        github = FakePreviewGitHub()
        github.create_preview()
        github.upload_preview_asset(42, "appcast-previous.xml" if backup else "appcast.xml", b"previous feed")
        github.events.clear()
        return github

    def test_creates_non_latest_prerelease_with_verified_feed(self):
        client = release.GitHub(REPOSITORY)
        with patch.object(client, "mutate", return_value={}) as mutate:
            client.create_preview()
            args = mutate.call_args.args
            self.assertEqual(args[:2], ("POST", "releases"))
            self.assertEqual(args[2]["tag_name"], "preview")
            self.assertTrue(args[2]["prerelease"])
            self.assertEqual(args[2]["make_latest"], "false")
        github = FakePreviewGitHub()
        release.publish_preview(github, self.output)
        self.assertEqual(github.asset_bytes("appcast.xml"), self.output.read_bytes())
        self.assertEqual(len(ET.fromstring(self.output.read_bytes()).findall("./channel/item")), 1)

    def test_upload_and_verification_precede_replacing_old_feed(self):
        github = self.existing_preview()
        release.publish_preview(github, self.output)
        upload_index = next(i for i, event in enumerate(github.events) if event[0] == "upload")
        staged_name = github.events[upload_index][1]
        verify_index = github.events.index(("read", staged_name))
        rename_index = next(i for i, event in enumerate(github.events) if event[0] == "rename")
        self.assertLess(upload_index, verify_index)
        self.assertLess(verify_index, rename_index)
        self.assertEqual(github.asset_bytes("appcast-previous.xml"), b"previous feed")
        self.assertEqual(github.asset_bytes("appcast.xml"), self.output.read_bytes())

    def test_unchanged_feed_needs_no_writes(self):
        github = self.existing_preview()
        release.publish_preview(github, self.output)
        github.events.clear()
        release.publish_preview(github, self.output)
        self.assertTrue(all(event[0] == "read" for event in github.events))

    def test_failed_upload_leaves_current_feed_untouched(self):
        github = self.existing_preview()
        with patch.object(github, "upload_preview_asset", side_effect=OSError("Upload failed")):
            with self.assertRaises(OSError):
                release.publish_preview(github, self.output)
        self.assertEqual(github.asset_bytes("appcast.xml"), b"previous feed")
        self.assertFalse(any(event[0] == "rename" for event in github.events))

    def test_failed_promotion_restores_old_feed_even_if_response_was_lost(self):
        for committed in [False, True]:
            with self.subTest(committed=committed):
                github = self.existing_preview()
                original = github.rename_asset
                def fail_promotion(asset_id, name):
                    if asset_id != 1 and name == "appcast.xml":
                        if committed:
                            original(asset_id, name)
                        raise OSError("Promotion response lost")
                    return original(asset_id, name)
                with patch.object(github, "rename_asset", side_effect=fail_promotion):
                    with self.assertRaises(OSError):
                        release.publish_preview(github, self.output)
                self.assertEqual(github.asset_bytes("appcast.xml"), b"previous feed")
                # A retry can reuse the staged asset and complete the swap.
                release.publish_preview(github, self.output)
                self.assertEqual(github.asset_bytes("appcast.xml"), self.output.read_bytes())

    def test_failed_public_verification_restores_old_feed(self):
        github = self.existing_preview()
        original = release.verify_preview_download
        def fail_live(client, name, data):
            if name == "appcast.xml":
                raise ValueError("Public feed mismatch")
            return original(client, name, data)
        with patch.object(release, "verify_preview_download", side_effect=fail_live):
            with self.assertRaises(ValueError):
                release.publish_preview(github, self.output)
        self.assertEqual(github.asset_bytes("appcast.xml"), b"previous feed")

    def test_interrupted_swap_recovers_backup_before_new_upload(self):
        github = self.existing_preview(backup=True)
        release.publish_preview(github, self.output)
        self.assertEqual(github.events[0], ("rename", 1, "appcast.xml"))
        self.assertEqual(github.asset_bytes("appcast.xml"), self.output.read_bytes())

    def test_rejects_stable_draft_and_immutable_preview_release(self):
        for field, value in [("prerelease", False), ("draft", True), ("immutable", True)]:
            with self.subTest(field=field):
                github = self.existing_preview()
                github.preview[field] = value
                with self.assertRaises(ValueError):
                    release.publish_preview(github, self.output)
                self.assertFalse(github.events)

    def test_reserved_preview_release_is_excluded_from_version_discovery(self):
        github = self.existing_preview()
        records = release.release_items(github, github.releases())
        self.assertEqual(len(records), 1)
        self.assertFalse(github.events)

    def test_rejects_empty_feed_without_creating_release(self):
        github = FakePreviewGitHub()
        github.data = []
        with self.assertRaises(ValueError):
            release.publish_preview(github, self.output)
        self.assertIsNone(github.preview)


if __name__ == "__main__":
    unittest.main()
