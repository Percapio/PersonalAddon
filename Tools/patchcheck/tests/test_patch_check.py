"""The patch check's tests, T1-T15 (Architecture/20261002-Phase10.md section 10.1)
and T16-T18 (Architecture/20261005-Phase11.md section 10.2).

T1, T2, T15 and T18 use the real exports and are skipped when one is missing. The
rest copy the small synthetic export in fixtures/base to a temporary folder and
change it.

Usage: python Tools/patchcheck/tests/test_patch_check.py
"""
import os
import pathlib
import re
import shutil
import sys
import tempfile
import time
import unittest

TOOLS = pathlib.Path(__file__).resolve().parents[2]
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from common import load_set, paths  # noqa: E402
from patchcheck import client_build, patch_check, premises, store, views  # noqa: E402

FIXTURE = TOOLS / "patchcheck" / "fixtures" / "base"
OLD_EXPORT = pathlib.Path(r"C:\tmp\BlizzardInterfaceCode-20260926")
BUILD = "1.60.1.70205"


class Crash(Exception):
    """Stands in for the process dying mid-accept: nothing after it runs."""


def known_build(binary):
    return BUILD, None


def unreadable_build(binary):
    return None, client_build.NO_VERSION_RESOURCE


def quiet(*_):
    return None


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.temporary = pathlib.Path(tempfile.mkdtemp(prefix="patchcheck-"))
        shutil.copytree(FIXTURE, self.temporary, dirs_exist_ok=True)
        self.export = self.temporary / "export"
        self.binary = self.temporary / "WowB.exe"
        self.binary.write_bytes(b"not a real client")
        self.age_binary()
        self.paths = patch_check.ToolPaths(
            repo=self.temporary / "addon", export=self.export, binary=self.binary,
            store=self.temporary / "store", register=self.temporary / "premises.toml",
            reports=self.temporary / "reports", verified=self.temporary / "verified.json",
            allowlist=self.temporary / "allow.txt", config=paths.load_config())

    def tearDown(self):
        shutil.rmtree(self.temporary, ignore_errors=True)

    def age_binary(self, seconds_before_export=3600):
        newest = views.newest_mtime(self.temporary / "export")
        stamp = newest - seconds_before_export
        os.utime(self.binary, (stamp, stamp))

    def file(self, relative):
        return paths.addons_root(self.export) / relative

    def edit(self, relative, old, new):
        path = self.file(relative)
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new), encoding="utf-8")
        self.age_binary()

    def append(self, relative, text):
        path = self.file(relative)
        path.write_text(path.read_text(encoding="utf-8") + text, encoding="utf-8")
        self.age_binary()

    def adopt(self):
        return patch_check.adopt(self.paths, build_reader=known_build, out=quiet)

    def check(self, build_reader=known_build):
        return patch_check.run_check(self.paths, build_reader=build_reader, out=quiet)

    def premise(self, result, premise_id):
        return next(item for item in result["premises"] if item["id"] == premise_id)

    def surface(self, result, name):
        return next((item for item in result["surface"] if item["name"] == name), None)


class FixtureTests(FixtureCase):
    def test_baseline_self_check_passes(self):
        self.adopt()
        result = self.check()
        self.assertEqual(result["verdict"]["kind"], "Pass", result["verdict"]["reasons"])
        names = {item["name"] for item in result["surface"]}
        for expected in ("UnitThreatSituation", "event CHAT_MSG_LOOT", "event CHAT_MSG_MONEY",
                         "lua CompactUnitFrame_UpdateAll", "lua ContainerFrameCombinedBags",
                         "registry ContainerFrame.OpenBag"):
            self.assertIn(expected, names)

    def test_t3_second_caller_breaks_the_sole_caller_premise(self):
        self.adopt()
        self.append("Blizzard_UIPanels/Bags.lua", "\nfunction Bags_Other()\n\tSetPreferredGamepadInteractTarget(nil);\nend\n")
        result = self.check()
        self.assertEqual(self.premise(result, "SOLE-CALLER")["status"], premises.BROKEN)
        self.assertEqual(result["verdict"]["kind"], "Fail")

    def test_t3_caller_in_an_xml_handler_is_seen(self):
        self.adopt()
        self.edit("Blizzard_UIPanels/Bags.xml", "Bags_OnShow(self);",
                  "Bags_OnShow(self);\n\t\t\t\tSetPreferredGamepadInteractTarget(nil);")
        result = self.check()
        outcome = self.premise(result, "SOLE-CALLER")
        self.assertEqual(outcome["status"], premises.BROKEN)
        self.assertIn("Blizzard_UIPanels/Bags.xml:9", outcome["evidence"])

    def test_t4_removed_hook_target_is_gone(self):
        self.adopt()
        self.edit("Blizzard_UnitFrame/Shared/CompactUnitFrame.lua",
                  "function CompactUnitFrame_UpdateAll(frame)\nend\n", "")
        result = self.check()
        self.assertEqual(self.surface(result, "lua CompactUnitFrame_UpdateAll")["change"], "Gone")
        self.assertEqual(result["verdict"]["kind"], "Fail")

    def test_t5_loot_chat_in_lockdown_breaks_its_premise(self):
        self.adopt()
        self.edit("Blizzard_APIDocumentationGenerated/ChatInfoDocumentation.lua",
                  'LiteralName = "CHAT_MSG_LOOT",',
                  'LiteralName = "CHAT_MSG_LOOT",\n\t\t\tSecretInChatMessagingLockdown = true,')
        result = self.check()
        self.assertEqual(self.premise(result, "LOOT-TEXT-READABLE")["status"], premises.BROKEN)
        self.assertEqual(result["verdict"]["kind"], "Fail")

    def test_t6_secret_threat_breaks_its_premise_and_changes_flags(self):
        self.adopt()
        self.edit("Blizzard_APIDocumentationGenerated/UnitDocumentation.lua",
                  "SecretWhenUnitThreatStateRestricted = true,",
                  "SecretWhenUnitThreatStateRestricted = true,\n\t\t\tSecretReturns = true,")
        result = self.check()
        self.assertEqual(self.premise(result, "THREAT-READABLE")["status"], premises.BROKEN)
        self.assertEqual(self.surface(result, "UnitThreatSituation")["change"], "FlagsChanged")
        self.assertEqual(result["verdict"]["kind"], "Fail")

    def test_t7_unknown_toc_tag_is_listed_and_reviewed(self):
        self.adopt()
        self.edit("Blizzard_UIPanels/Blizzard_UIPanels.toc", "Bags.lua", "Bags.lua [SomeNewTag value]")
        result = self.check()
        self.assertTrue(any("SomeNewTag" in tag for tag in result["loadSet"]["unknownTags"]))
        self.assertEqual(result["verdict"]["kind"], "Review")
        self.assertEqual(self.premise(result, "SOLE-CALLER")["status"], premises.HOLDS)

    def test_t8_definition_moved_to_a_classic_only_file_is_gone(self):
        self.adopt()
        self.edit("Blizzard_UnitFrame/Shared/CompactUnitFrame.lua",
                  "function CompactUnitFrame_UpdateHealthColor(frame)", "local function NotAnymore(frame)")
        self.append("Blizzard_UnitFrame/Vanilla/UnitFrameClassic.lua",
                    "\nfunction CompactUnitFrame_UpdateHealthColor(frame)\nend\n")
        result = self.check()
        self.assertEqual(self.surface(result, "lua CompactUnitFrame_UpdateHealthColor")["change"], "Gone")
        self.assertEqual(result["verdict"]["kind"], "Fail")

    def test_t9_degraded_check_without_the_store_copy(self):
        self.adopt()
        shutil.rmtree(self.paths.store / store.EXPORT)
        result = self.check()
        self.assertTrue(result["degraded"])
        self.assertEqual(self.premise(result, "COLOUR")["status"], premises.HOLDS)
        self.assertEqual(result["verdict"]["kind"], "Review")
        self.assertTrue(any("degraded" in reason for reason in result["verdict"]["reasons"]))
        self.edit("Blizzard_UnitFrame/Shared/CompactUnitFrame.lua", "end\n", "end\n-- changed\n")
        result = self.check()
        self.assertEqual(self.premise(result, "COLOUR")["status"], premises.NEEDS_REVIEW)
        self.assertNotIn("diff", result["watched"][0])

    def test_t10_interrupted_accept_recovers_to_a_consistent_store(self):
        steps = ["copied", "manifest-new", "between-renames", "renamed", "committed", "verified"]
        for step in steps:
            with self.subTest(step=step):
                self.tearDown()
                self.setUp()
                self.adopt()
                old_digest = store.read_json(self.paths.verified)["exportDigest"]
                self.edit("Blizzard_UnitFrame/Shared/CompactUnitFrame.lua", "end\n", "end\n-- new build\n")
                self.check()

                def fault(at, stop=step):
                    if at == stop:
                        raise Crash(at)

                with self.assertRaises(Crash):
                    patch_check.accept(self.paths, reviewed=True, build_reader=known_build,
                                       fault=fault, out=quiet)
                kind, lines = patch_check.status(self.paths, build_reader=known_build)
                committed = steps.index(step) >= steps.index("committed")
                self.assertEqual(kind, "RecoveryPending")
                if step == "committed":
                    self.assertTrue(any("accept --resume" in line for line in lines))
                    patch_check.accept(self.paths, resume=True, build_reader=known_build, out=quiet)
                store.recover(self.paths.store, self.paths.verified)
                manifest = store.read_json(self.paths.store / store.MANIFEST)
                verified = store.read_json(self.paths.verified)
                hashes, _ = views.hash_export(self.paths.store / store.EXPORT)
                self.assertEqual(manifest["record"]["exportDigest"], verified["exportDigest"])
                self.assertEqual(views.export_digest(hashes), verified["exportDigest"])
                self.assertEqual(verified["exportDigest"] != old_digest, committed)
                for leftover in (store.EXPORT_NEW, store.EXPORT_OLD, store.MANIFEST_NEW):
                    self.assertFalse((self.paths.store / leftover).exists(), leftover)

    def test_t11_invalid_register_names_every_fault(self):
        self.paths.register.write_text(
            '[[premise]]\nid = "A"\nstatement = "s"\nsource = "s"\nconsequence = "c"\n'
            'check = { kind = "Watch", files = ["../outside.lua"] }\n'
            '[[premise]]\nid = "A"\nstatement = "s"\nsource = "s"\nconsequence = "c"\n'
            'check = { kind = "Pattern", file = "x.lua", regex = "(unclosed", expect = "Present" }\n',
            encoding="utf-8")
        with self.assertRaises(premises.RegisterInvalid) as raised:
            premises.load_register(self.paths.register)
        faults = " | ".join(raised.exception.faults)
        self.assertIn("bad path", faults)
        self.assertIn("duplicate id", faults)
        self.assertIn("bad regex", faults)

    def test_t12_stale_export_is_refused(self):
        self.adopt()
        newest = views.newest_mtime(self.export)
        os.utime(self.binary, (newest + 60, newest + 60))
        kind, _ = patch_check.status(self.paths, build_reader=known_build)
        self.assertEqual(kind, "ExportStale")
        with self.assertRaises(patch_check.Refused) as raised:
            self.check()
        self.assertEqual(raised.exception.kind, "ExportStale")

    def test_t13_unreadable_build_compares_by_file_time(self):
        record = patch_check.adopt(self.paths, build_reader=unreadable_build, out=quiet)
        self.assertIsNone(record["client"]["build"])
        kind, lines = patch_check.status(self.paths, build_reader=unreadable_build)
        self.assertEqual(kind, "UpToDate")
        self.assertTrue(any("compared by WowB.exe's time" in line for line in lines))
        result = self.check(build_reader=unreadable_build)
        self.assertTrue(result["report"].endswith(f"unknown-{int(os.path.getmtime(self.binary))}.md"))
        later = os.path.getmtime(self.binary) - 10
        os.utime(self.binary, (later, later))
        kind, _ = patch_check.status(self.paths, build_reader=unreadable_build)
        self.assertEqual(kind, "CheckDue")

    def test_t14_export_changed_after_check_is_refused(self):
        self.adopt()
        self.edit("Blizzard_UnitFrame/Shared/CompactUnitFrame.lua", "end\n", "end\n-- one\n")
        self.check()
        before = store.read_json(self.paths.store / store.MANIFEST)
        self.edit("Blizzard_UnitFrame/Shared/CompactUnitFrame.lua", "-- one", "-- two")
        with self.assertRaises(patch_check.Refused) as raised:
            patch_check.accept(self.paths, reviewed=True, build_reader=known_build, out=quiet)
        self.assertEqual(raised.exception.kind, "ExportChangedSinceCheck")
        self.assertEqual(store.read_json(self.paths.store / store.MANIFEST), before)

    def test_review_needs_reviewed_and_fail_is_refused(self):
        self.adopt()
        self.edit("Blizzard_UnitFrame/Shared/CompactUnitFrame.lua", "end\n", "end\n-- reviewed\n")
        self.check()
        with self.assertRaises(patch_check.Refused) as raised:
            patch_check.accept(self.paths, build_reader=known_build, out=quiet)
        self.assertEqual(raised.exception.kind, "NotReviewed")
        record = patch_check.accept(self.paths, reviewed=True, build_reader=known_build, out=quiet)
        self.assertEqual(record["acceptedBy"], "AcceptedAfterReview")
        self.append("Blizzard_UIPanels/Bags.lua", "\nSetPreferredGamepadInteractTarget(nil)\n")
        self.check()
        with self.assertRaises(patch_check.Refused) as raised:
            patch_check.accept(self.paths, reviewed=True, build_reader=known_build, out=quiet)
        self.assertEqual(raised.exception.kind, "VerdictFail")

    def test_t16_flag_equals_holds_when_the_value_matches(self):
        self.adopt()
        result = self.check()
        outcome = self.premise(result, "ARGUMENTS-UNTAINTED")
        self.assertEqual(outcome["status"], premises.HOLDS, outcome["evidence"])
        self.assertEqual(result["verdict"]["kind"], "Pass", result["verdict"]["reasons"])

    def test_t17_flag_equals_breaks_on_a_new_value_then_on_removal(self):
        self.adopt()
        self.edit("Blizzard_APIDocumentationGenerated/UnitDocumentation.lua",
                  'SecretArguments = "AllowedWhenUntainted",', 'SecretArguments = "NotAllowed",')
        result = self.check()
        outcome = self.premise(result, "ARGUMENTS-UNTAINTED")
        self.assertEqual(outcome["status"], premises.BROKEN)
        self.assertIn('"NotAllowed"', outcome["evidence"])
        self.assertEqual(result["verdict"]["kind"], "Fail")
        self.edit("Blizzard_APIDocumentationGenerated/UnitDocumentation.lua",
                  'Name = "UnitThreatSituation",', 'Name = "UnitThreatSituationRenamed",')
        result = self.check()
        outcome = self.premise(result, "ARGUMENTS-UNTAINTED")
        self.assertEqual(outcome["status"], premises.BROKEN)
        self.assertIn("no longer documented", outcome["evidence"])

    def test_t17_flag_equals_needs_a_value(self):
        self.paths.register.write_text(
            '[[premise]]\nid = "A"\nstatement = "s"\nsource = "s"\nconsequence = "c"\n'
            'check = { kind = "FlagEquals", entry = "UnitThreatSituation", flag = "SecretArguments" }\n',
            encoding="utf-8")
        with self.assertRaises(premises.RegisterInvalid) as raised:
            premises.load_register(self.paths.register)
        self.assertIn("FlagEquals needs entry, flag and value", " | ".join(raised.exception.faults))

    def test_classic_only_file_is_outside_the_load_set(self):
        loaded = load_set.resolve_load_set(self.export, self.paths.config)
        self.assertIn("Blizzard_UnitFrame/Mainline/UnitFrame.lua", loaded.files)
        self.assertNotIn("Blizzard_UnitFrame/Vanilla/UnitFrameClassic.lua", loaded.files)
        self.assertIn("Blizzard_UIPanels/Bags.xml", loaded.files)


@unittest.skipUnless(paths.docs_root(paths.EXPORT).is_dir(), "the current export is missing")
class RealExportTests(unittest.TestCase):
    def make_paths(self, temporary):
        tool_paths = patch_check.default_paths()
        tool_paths.store = temporary / "store"
        tool_paths.reports = temporary / "reports"
        tool_paths.verified = temporary / "verified.json"
        return tool_paths

    def test_t1_the_current_export_against_itself_passes(self):
        temporary = pathlib.Path(tempfile.mkdtemp(prefix="patchcheck-t1-"))
        try:
            tool_paths = self.make_paths(temporary)
            patch_check.adopt(tool_paths, out=quiet)
            result = patch_check.run_check(tool_paths, out=quiet)
            self.assertEqual(result["verdict"]["kind"], "Pass", result["verdict"]["reasons"])
            self.assertTrue(all(item["status"] == premises.HOLDS for item in result["premises"]))
        finally:
            shutil.rmtree(temporary, ignore_errors=True)

    @unittest.skipUnless(paths.docs_root(OLD_EXPORT).is_dir(), "the 09-26 export is missing")
    def test_t2_reproduces_gapbugs01_section_1_4(self):
        temporary = pathlib.Path(tempfile.mkdtemp(prefix="patchcheck-t2-"))
        try:
            tool_paths = self.make_paths(temporary)
            result = patch_check.run_check(tool_paths, baseline_export=OLD_EXPORT, out=quiet)
            self.assertEqual(result["verdict"]["kind"], "Review")
            self.assertEqual(result["exportModifiedCount"], 127)
            self.assertEqual(result["exportAdded"], ["Blizzard_AchievementUI/Camelot/Blizzard_AchievementUI.lua",
                                                     "Blizzard_ProjectConstants/Camelot/ProjectConstants.lua"])
            self.assertEqual(result["exportRemoved"], [])
            by_id = {item["id"]: item for item in result["premises"]}
            self.assertEqual(sorted(by_id["G1-PATH"]["changedFiles"]), [
                "Blizzard_GamepadActionBars/PageUnit.lua",
                "Blizzard_GamepadSharedUtility/InputBindingStack/BindingSetFactory.lua",
                "Blizzard_GamepadSmartNavigation/SmartNavigation.lua"])
            self.assertEqual(by_id["PLATE-COLOUR"]["status"], premises.NEEDS_REVIEW)
            self.assertEqual(by_id["FORBIDDEN-DIALOG"]["status"], premises.NEEDS_REVIEW)
            self.assertEqual(by_id["PLAYER-FRAME"]["status"], premises.NEEDS_REVIEW)
            others = set(by_id) - {"G1-PATH", "PLATE-COLOUR", "FORBIDDEN-DIALOG", "PLAYER-FRAME"}
            self.assertTrue(all(by_id[name]["status"] == premises.HOLDS for name in others))
            changes = {item["file"]: (item["added"], item["removed"]) for item in result["watched"]}
            self.assertEqual(changes["Blizzard_GamepadSmartNavigation/SmartNavigation.lua"], (80, 5))
            self.assertEqual(changes["Blizzard_GamepadSharedUtility/InputBindingStack/BindingSetFactory.lua"], (0, 10))
            self.assertEqual(changes["Blizzard_GamepadActionBars/PageUnit.lua"], (4, 2))
            self.assertFalse([item for item in result["surface"] if item["change"] == "Gone"])
            self.assertIn("UnitUsesAmmo", result["docsAdded"])
            for name in ("UnitIsUnit", "UnitInRaid", "UnitThreatSituation", "UnitDetailedThreatSituation"):
                self.assertNotIn(name, result["docsFlagsChanged"])
        finally:
            shutil.rmtree(temporary, ignore_errors=True)

    def test_t18_the_phase11_premises_hold_on_the_current_export(self):
        register = premises.load_register(patch_check.default_paths().register)
        self.assertEqual(len(register), 22)
        current = views.build_view(paths.EXPORT, paths.load_config(), premises.call_names(register))
        by_id = {premise.id: premise for premise in register}
        for premise_id in ("BAR-VALUE-TAKES-HIDDEN", "BAR-RANGE-TAKES-HIDDEN", "TEXT-TAKES-HIDDEN",
                           "FORMATTED-TEXT-TAKES-HIDDEN", "THREAT-PERCENT-READABLE",
                           "PLATE-LOOKUP-READABLE", "PLATE-UNIT-TOKEN"):
            outcome = premises.evaluate_premise(by_id[premise_id], current, None)
            self.assertEqual(outcome.status, premises.HOLDS, f"{premise_id}: {outcome.evidence}")

    def test_t15_every_file_in_running_stacks_is_in_the_load_set(self):
        loaded = {name.lower() for name in load_set.resolve_load_set(paths.EXPORT).files}
        account = paths.CLIENT / "WTF" / "Account"
        sources = list(account.rglob("!BugGrabber.lua*")) + \
            list((paths.REPO / "BlizzardBugLogs").glob("*.log"))
        pattern = re.compile(r"Interface/AddOns/(Blizzard_[A-Za-z0-9_]+/[A-Za-z0-9_/]+[.](?:lua|xml))")
        seen = set()
        for source in sources:
            text = source.read_text(encoding="utf-8", errors="replace").replace("\\", "/")
            seen.update(match.group(1) for match in pattern.finditer(text))
        if not seen:
            self.skipTest("no stacks on disk")
        self.assertEqual(sorted(name for name in seen if name.lower() not in loaded), [])


if __name__ == "__main__":
    started = time.time()
    unittest.main(verbosity=2, exit=False)
    print(f"took {time.time() - started:.1f}s")
