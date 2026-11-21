import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
import reset_screen

FIXTURE_BIN = Path(__file__).resolve().parent / "fixtures" / "bin"

def git(cwd, *args, env=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True, env=env).stdout


class PanePollTests(unittest.TestCase):
    def test_no_report_guide_uses_pinned_listener(self):
        guide = (Path(__file__).resolve().parent.parent / "references" / "guide.md").read_text()
        fallback = guide.split("### 3.2 Status is unreliable for Codex", 1)[1].split("### 3.3", 1)[0]
        self.assertNotIn("scripts/poll-idle.sh", fallback)
        self.assertIn("listen-notify.py start", fallback)
        self.assertIn("--poll idle", fallback)
        self.assertIn("--agent-pane", fallback)

    def test_all_pollers_retry_transient_get_and_bound_consecutive_failures(self):
        scripts = Path(__file__).resolve().parent
        for mode in ("idle", "handoff", "report"):
            for failures in (1, 5):
                with self.subTest(mode=mode, failures=failures), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    count = root / "count"
                    herdr = root / "herdr"
                    herdr.write_text("#!/usr/bin/env python3\nimport json, sys\nfrom pathlib import Path\n"
                        "if sys.argv[2] == 'read': print('Worked for 1m'); sys.exit(0)\n"
                        f"count = Path({str(count)!r})\n"
                        "n = int(count.read_text()) + 1 if count.exists() else 1\n"
                        "count.write_text(str(n))\n"
                        f"if n <= {failures}: sys.stderr.write('temporary lookup failure'); sys.exit(1)\n"
                        "print(json.dumps({'result': {'type': 'agent_info', 'agent': "
                        "{'terminal_id': 'term_abc123', 'agent_status': 'done'}}}))\n")
                    herdr.chmod(0o755)
                    sleep = root / "sleep"
                    sleep.write_text("#!/bin/sh\nexit 0\n")
                    sleep.chmod(0o755)
                    report = root / "report.md"
                    report.write_text("Report-Task: retry\n")
                    config = root / "config.json"
                    config.write_text('{"created_at": 0}')
                    args = {"idle": ["worker", "0", "10"],
                        "handoff": ["worker", str(report), "10", ""],
                        "report": ["worker", str(report), str(config), "retry", "0", "10", "1"]}[mode]
                    executable = ([sys.executable, str(scripts / "poll-report.py")] if mode == "report"
                                  else [str(scripts / f"poll-{mode}.sh")])
                    result = subprocess.run([*executable, *args, "w1:p3", "term_abc123"],
                        capture_output=True, text=True, timeout=5,
                        env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"]})
                    if failures == 1:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("worker " + ("idle" if mode == "idle" else "done"), result.stdout)
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertIn("5 consecutive", result.stderr)
                        self.assertEqual(count.read_text(), "5")

    def test_shell_pollers_use_pane_and_reject_replaced_terminal_before_completion(self):
        scripts = Path(__file__).resolve().parent
        for mode in ("idle", "handoff"):
            for mismatch in (False, True):
                with self.subTest(mode=mode, mismatch=mismatch), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    calls = root / "calls"
                    herdr = root / "herdr"
                    herdr.write_text("#!/usr/bin/env python3\n"
                        "import json, sys\n"
                        f"with open({str(calls)!r}, 'a') as f: f.write(' '.join(sys.argv[1:]) + '\\n')\n"
                        "if sys.argv[2:4] == ['read', 'w1:p3']:\n"
                        "    print('Worked for 1m'); sys.exit(0)\n"
                        "if sys.argv[2:4] != ['get', 'w1:p3']:\n"
                        "    sys.stderr.write('agent_not_found'); sys.exit(1)\n"
                        f"terminal = 'term_replaced' if {mismatch!r} else 'term_abc123'\n"
                        "print(json.dumps({'result': {'type': 'agent_info', 'agent': "
                        "{'name': '', 'pane_id': 'w1:p3', 'terminal_id': terminal, "
                        "'agent_status': 'done'}}}))\n")
                    herdr.chmod(0o755)
                    sleep = root / "sleep"
                    sleep.write_text("#!/bin/sh\nexit 0\n")
                    sleep.chmod(0o755)
                    report = root / "report.md"
                    report.write_text("DONE\n")
                    args = (["worker", "1", "1"] if mode == "idle" else
                            ["worker", str(report), "1", "DONE"])
                    result = subprocess.run([str(scripts / f"poll-{mode}.sh"), *args,
                                             "w1:p3", "term_abc123"], capture_output=True, text=True,
                        env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"]}, timeout=5)
                    if mismatch:
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertIn("terminal mismatch", result.stdout + result.stderr)
                        self.assertIn("term_replaced", result.stdout + result.stderr)
                    else:
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn("worker " + ("idle" if mode == "idle" else "done"), result.stdout)
                    self.assertNotIn("worker", calls.read_text())
                    self.assertIn("agent get w1:p3", calls.read_text())


class RebaseVerifyTests(unittest.TestCase):
    """rebase-verify.sh compares an audited range with its rebased range."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
        git(self.repo, "init", "-q", "-b", "main", env=self.env)
        (self.repo / "App").mkdir()
        (self.repo / "App/blob.bin").write_bytes(b"\x00original\xff")
        git(self.repo, "add", "App/blob.bin", env=self.env)
        self.commit("init", **{"App/a.swift": "a\n", "App/b.swift": "b\n", "notes.md": "n\n"})
        self.old_base = self.head()
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a2\n"})
        self.old_head = self.head()
        git(self.repo, "switch", "-qc", "rebased", self.old_base, env=self.env)
        self.commit("docs: main moved", **{"notes.md": "n2\n", "App/b.swift": "b2\n"})
        self.new_base = self.head()

    def tearDown(self):
        self.tmp.cleanup()

    def head(self):
        return git(self.repo, "rev-parse", "HEAD").strip()

    def commit(self, message, **files):
        for path, text in files.items():
            (self.repo / path).write_text(text)
        git(self.repo, "add", *files, env=self.env)
        git(self.repo, "commit", "-qm", message, env=self.env)

    def verify(self):
        return subprocess.run([str(Path(__file__).with_name("rebase-verify.sh")), self.old_base, self.old_head,
                               self.new_base, self.head()], cwd=self.repo, capture_output=True, text=True)

    def test_same_patch_on_a_moved_base_passes(self):
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a2\n"})

        result = self.verify()

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE same", result.stdout)

    def test_conflict_resolution_that_changes_code_exits_1(self):
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a3\n"})

        result = self.verify()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_app_tests_only_difference_exits_1(self):
        (self.repo / "AppTests").mkdir()
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a2\n", "AppTests/AppTests.swift": "test\n"})

        result = self.verify()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_ui_tests_only_difference_exits_1(self):
        (self.repo / "UITests").mkdir()
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{"App/a.swift": "a2\n", "UITests/UITests.swift": "test\n"})

        result = self.verify()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_dropped_hash_line_exits_2(self):
        self.commit("feat: topic", **{"App/a.swift": "a2\n"})

        result = self.verify()

        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("MESSAGES differ", result.stdout)

    def test_test_and_tooling_only_patches_same_or_different(self):
        for path in ("AppTests/Only.swift", "UITests/Only.swift", "scripts/check.sh", ".github/workflows/check.yml"):
            for same in (True, False):
                with self.subTest(path=path, same=same):
                    git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
                    (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
                    self.commit("test: patch", **{path: "old patch\n"})
                    self.old_head = self.head()
                    git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
                    (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
                    self.commit("test: patch", **{path: "old patch\n" if same else "changed patch\n"})
                    result = self.verify()
                    self.assertEqual(result.returncode, 0 if same else 1, result.stdout + result.stderr)
                    self.assertIn("CODE same" if same else "CODE differ", result.stdout)
                    self.assertNotIn("da39a3ee5e6b4b0d3255bfef95601890afd80709", result.stdout)

    def test_empty_input_on_either_side_fails_loudly(self):
        script = str(Path(__file__).with_name("rebase-verify.sh"))
        for old_empty, new_empty in ((True, True), (True, False), (False, True)):
            with self.subTest(old_empty=old_empty, new_empty=new_empty):
                result = subprocess.run([script, self.old_base, self.old_base if old_empty else self.old_head,
                                         self.old_base, self.old_base if new_empty else self.old_head],
                                        cwd=self.repo, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("empty", (result.stdout + result.stderr).lower())
                self.assertNotIn("CODE same", result.stdout)
                self.assertNotIn("da39a3ee", result.stdout)

    def test_full_patch_identity_mutations_differ(self):
        for mutation in ("rename", "deletion", "chmod", "binary", "different-path",
                         "package-lock.json", "design/state.html", "--flag", "++flag"):
            with self.subTest(mutation=mutation):
                git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
                if mutation == "different-path":
                    (self.repo / "App/other.swift").write_text("a2\n")
                else:
                    (self.repo / "App/a.swift").write_text("a2\n")
                if mutation == "rename":
                    git(self.repo, "mv", "App/b.swift", "App/c.swift", env=self.env)
                elif mutation == "deletion":
                    git(self.repo, "rm", "App/b.swift", env=self.env)
                elif mutation == "chmod":
                    (self.repo / "App/b.swift").chmod(0o755)
                elif mutation == "binary":
                    (self.repo / "App/blob.bin").write_bytes(b"\x00changed\xff")
                elif mutation in ("--flag", "++flag"):
                    with (self.repo / "App/a.swift").open("a") as f:
                        f.write(mutation + "\n")
                elif mutation in ("package-lock.json", "design/state.html"):
                    path = self.repo / mutation
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("changed\n")
                git(self.repo, "add", "-A", env=self.env)
                git(self.repo, "commit", "-qm", "feat: topic\n\n#7 P1-01 VIEW-01", env=self.env)
                result = self.verify()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("CODE differ", result.stdout)

    def test_identical_edit_in_a_different_existing_path_differs(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("base", **{"App/b.swift": "a\n"})
        self.old_base = self.head()
        self.new_base = self.old_base
        self.commit("edit", **{"App/a.swift": "a2\n"})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
        self.commit("edit", **{"App/b.swift": "a2\n"})
        result = self.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CODE differ", result.stdout)

    def test_removing_double_minus_source_line_is_significant(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("base", **{"App/a.swift": "a\n--flag\n"})
        self.old_base = self.new_base = self.head()
        self.commit("edit", **{"App/a.swift": "a2\n--flag\n"})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
        self.commit("edit", **{"App/a.swift": "a2\n"})
        result = self.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CODE differ", result.stdout)

    def test_rebase_preserves_patch_with_shifted_hunks_and_blob_ids(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("base", **{"App/a.swift": "before 1\nbefore 2\nbefore 3\nprefix\na\nsuffix\n"})
        self.old_base = self.head()
        self.commit("edit", **{"App/a.swift": "before 1\nbefore 2\nbefore 3\nprefix\na2\nsuffix\n"})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("upstream", **{"App/a.swift": "upstream\nbefore 1\nbefore 2\nbefore 3\nprefix\na\nsuffix\n"})
        self.new_base = self.head()
        git(self.repo, "cherry-pick", self.old_head, env=self.env)
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CODE same", result.stdout)

    def compare_edits(self, base, old_edit, new_edit):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("base", **{"App/a.swift": base})
        self.old_base = self.new_base = self.head()
        self.commit("edit", **{"App/a.swift": old_edit})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
        self.commit("edit", **{"App/a.swift": new_edit})
        return self.verify()

    def test_identical_u3_context_in_different_blocks_differs(self):
        body = "context\n" * 5 + "target\n" + "after\n" * 5
        base = "first\n" + body + "second\n" + body
        first_edit = base.replace("target\n", "edited\n", 1)
        second_edit = base[:base.index("second\n")] + base[base.index("second\n"):].replace(
            "target\n", "edited\n", 1)
        result = self.compare_edits(base, first_edit, second_edit)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE differ", result.stdout)
        self.assertIn("replayed tree differs", result.stdout)
        self.assertNotRegex(result.stdout, r"CODE differ ([0-9a-f]+) -> \1")

    def test_helper_git_failure_is_concise(self):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("rebase-verify-tree.py")),
                                 str(self.repo), "invalid-ref", self.old_head, self.new_base, self.head()],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rebase-verify:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_repeated_context_locations_survive_distant_upstream_shifts(self):
        initial_base = self.old_base
        for delete_prefix in (False, True):
            with self.subTest(delete_prefix=delete_prefix):
                self.old_base = initial_base
                git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
                prefix = "".join(f"prefix {i}\n" for i in range(1, 31))
                body = "context\n" * 5 + "target\n" + "after\n" * 5
                blocks = "first\n" + body + "second\n" + body
                self.commit("base", **{"App/a.swift": prefix + blocks})
                self.old_base = self.head()
                self.commit("edit", **{"App/a.swift": (prefix + blocks).replace("target\n", "edited\n", 1)})
                self.old_head = self.head()
                git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
                shifted = ("" if delete_prefix else prefix + prefix) + blocks
                self.commit("upstream", **{"App/a.swift": shifted})
                self.new_base = self.head()
                git(self.repo, "cherry-pick", self.old_head, env=self.env)
                # Real index and unstaged work must survive comparison.
                (self.repo / "notes.md").write_text("staged scratch\n")
                git(self.repo, "add", "notes.md", env=self.env)
                (self.repo / "notes.md").write_text("unstaged scratch\n")
                before = (self.head(), git(self.repo, "diff", "--binary"),
                          git(self.repo, "diff", "--cached", "--binary"))
                result = self.verify()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("CODE same", result.stdout)
                self.assertEqual(before, (self.head(), git(self.repo, "diff", "--binary"),
                                         git(self.repo, "diff", "--cached", "--binary")))
                git(self.repo, "restore", "--staged", "notes.md", env=self.env)
                git(self.repo, "restore", "notes.md", env=self.env)
                git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
                second = shifted.index("second\n")
                self.commit("edit", **{"App/a.swift": shifted[:second] + shifted[second:].replace(
                    "target\n", "edited\n", 1)})
                result = self.verify()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("CODE differ", result.stdout)

    def test_upstream_deleting_original_block_cannot_retarget_identical_block(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        body = "context\n" * 5 + "target\n" + "after\n" * 5
        base = "first\n" + body + "second\n" + body
        self.commit("base", **{"App/a.swift": base})
        self.old_base = self.head()
        self.commit("edit", **{"App/a.swift": base.replace("target\n", "edited\n", 1)})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        surviving = "second\n" + body
        self.commit("upstream", **{"App/a.swift": surviving})
        self.new_base = self.head()
        self.commit("edit", **{"App/a.swift": surviving.replace("target\n", "edited\n", 1)})
        result = self.verify()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_nearby_upstream_context_exact_replay_passes(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        base = "".join(f"line {i}\n" for i in range(1, 31))
        self.commit("base", **{"App/a.swift": base})
        self.old_base = self.head()
        self.commit("edit", **{"App/a.swift": base.replace("line 10\n", "edited 10\n")})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("upstream", **{"App/a.swift": base.replace("line 8\n", "upstream 8\n")})
        self.new_base = self.head()
        git(self.repo, "cherry-pick", self.old_head, env=self.env)
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE same", result.stdout)

        # #449 expressly changes only the honest cherry-pick expectation above.
        self.commit("altered candidate", **{"App/a.swift": base.replace("line 8\n", "upstream 8\n").replace("line 10\n", "wrong 10\n")})
        result = self.verify()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("CODE differ", result.stdout)

    def test_replacing_first_or_second_identical_line_differs(self):
        result = self.compare_edits("a\nmiddle\na\n", "b\nmiddle\na\n", "a\nmiddle\nb\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_inserting_same_return_at_different_locations_differs(self):
        lines = [f"line {i}\n" for i in range(1, 41)]
        result = self.compare_edits("".join(lines), "".join(lines[:5] + ["return\n"] + lines[5:]),
                                    "".join(lines[:30] + ["return\n"] + lines[30:]))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_deleting_first_or_last_identical_line_differs(self):
        result = self.compare_edits("}\nmiddle\n}\n", "middle\n}\n", "}\nmiddle\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE differ", result.stdout)

    def test_function_suffix_context_distinguishes_identical_nearby_lines(self):
        body = "    context\n" * 5 + "    return old\n" + "    context\n" * 5
        base = "func first() {\n" + body + "}\nfunc second() {\n" + body + "}\n"
        result = self.compare_edits(base, base.replace("    return old", "    return new", 1),
                                    base[:base.index("func second")] +
                                    base[base.index("func second"):].replace("    return old", "    return new", 1))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CODE differ", result.stdout)

    def test_rebase_preserves_patch_when_distant_hunk_in_same_file_changes(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        base = "".join(f"line {i}\n" for i in range(1, 61))
        self.commit("base", **{"App/a.swift": base})
        self.old_base = self.head()
        self.commit("edit", **{"App/a.swift": base.replace("line 10\n", "edited 10\n")})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        self.commit("upstream", **{"App/a.swift": base.replace("line 50\n", "upstream 50\n")})
        self.new_base = self.head()
        git(self.repo, "cherry-pick", self.old_head, env=self.env)
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MESSAGES same", result.stdout)
        self.assertIn("CODE same", result.stdout)

    def test_subdirectory_invocation_compares_the_whole_repository(self):
        git(self.repo, "switch", "--detach", "-q", self.old_base, env=self.env)
        (self.repo / "sub").mkdir()
        self.commit("base", **{"sub/s.txt": "base\n"})
        self.old_base = self.new_base = self.head()
        self.commit("edit", **{"sub/s.txt": "same\n", "App/a.swift": "old edit\n"})
        self.old_head = self.head()
        git(self.repo, "switch", "--detach", "-q", self.new_base, env=self.env)
        self.commit("edit", **{"sub/s.txt": "same\n", "App/a.swift": "new edit\n"})
        root = self.verify()
        sub = subprocess.run([str(Path(__file__).with_name("rebase-verify.sh").resolve()),
                              self.old_base, self.old_head, self.new_base, self.head()],
                             cwd=self.repo / "sub", capture_output=True, text=True)
        self.assertEqual(root.returncode, 1, root.stdout + root.stderr)
        self.assertIn("CODE differ", root.stdout)
        self.assertEqual(sub.returncode, root.returncode, sub.stdout + sub.stderr)
        self.assertEqual(sub.stdout, root.stdout)

    def test_generated_ledger_is_excluded_and_ledger_only_is_empty(self):
        (self.repo / "docs").mkdir()
        self.commit("feat: topic\n\n#7 P1-01 VIEW-01", **{
            "App/a.swift": "a2\n", "docs/feature-ledger.md": "generated\n",
            "docs/feature-ledger.html": "generated html\n"})
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CODE same", result.stdout)
        self.old_base = self.new_base = self.head()
        self.commit("ledger only", **{"docs/feature-ledger.md": "regenerated\n"})
        self.old_head = self.head()
        result = self.verify()
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("empty", result.stderr)

    def test_unknown_commit_exits_3(self):
        result = subprocess.run([str(Path(__file__).with_name("rebase-verify.sh")), "nope", "HEAD", "HEAD",
                                 "HEAD"], cwd=self.repo, capture_output=True, text=True)

        self.assertEqual(result.returncode, 3, result.stdout)


LIVE_RESET_SCREEN = Path(__file__).with_name("fixtures").joinpath("reset-fresh-codex.txt").read_text()
# Codex 0.167.1 (2026-11-11): a "permissions:" header line and a "← for agents · ? for shortcuts" hint line
# with a warnings tail; reset.sh reported a false "no new-session boundary" FAIL on it (#34).
LIVE_RESET_SCREEN_0167 = Path(__file__).with_name("fixtures").joinpath("reset-fresh-codex-0167.txt").read_text()



def run_screen_reset(self, *, delay=0, context="Context 0% used", deadline="2", poll="0.01",
                     prefix="", startup=">_ OpenAI Codex (v0.166.0)",
                     ready_boundary=">_ OpenAI Codex (v0.166.0)", locale=None, old_context="",
                     session_before="", session_after="", session_delay=0):
    """Replay finite pane events through the production controller using virtual time."""
    now = 0.0
    reads = 0
    gets = 1  # initial pane identity, before /new

    def session():
        nonlocal gets
        gets += 1
        return session_after if reads >= session_delay else session_before

    def read():
        nonlocal reads
        screen = startup if reads < delay or not context else ready_boundary + "\n" + context
        reads += 1
        return prefix + "\n" + screen + "\n"

    def advance(seconds):
        nonlocal now
        now += seconds

    kind, context = reset_screen.wait_for_context(read, session, session_before,
        float(deadline), float(poll), sleep=advance, monotonic=lambda: now)
    code, output = reset_screen.outcome("fixture-agent", session_before or "old-session", deadline, kind, context)
    result = subprocess.CompletedProcess([], code, output, "")
    result.pane_gets = gets
    return result, now

class ResetTests(unittest.TestCase):
    """Run the real reset CLI through chooser/startup/context transitions."""

    run_screen_reset = run_screen_reset

    SUCCESS = ("reset fixture-agent old_session=old-session Context 0% used "
               "(verify the session id changes after the next turn)\n")

    def run_reset(self, *, delay=0, context="Context 0% used", status="idle", chooser=True, deadline="2",
                  poll="0.01", prefix="", startup=">_ OpenAI Codex (v0.166.0)", timer_var=None, old_context="",
                  ready_boundary=">_ OpenAI Codex (v0.166.0)", locale=None, session_before="", session_after="", session_delay=0, pane_height=0,
                  agent_get="", agent_get_exit=1, herdr_override=None, use_defaults=False):
        import time

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = {**os.environ, "PATH": str(FIXTURE_BIN / "path-default") + os.pathsep + os.environ["PATH"],
                   "RCLICK_HERDR": str(FIXTURE_BIN / "herdr-reset"), "RCLICK_SLEEP": str(FIXTURE_BIN / "sleep"),
                   "RESET_SESSION_BEFORE": session_before, "RESET_SESSION_AFTER": session_after,
                   "RESET_SESSION_DELAY": str(session_delay),
                   "RESET_AGENT_GET": agent_get, "RESET_AGENT_GET_EXIT": str(agent_get_exit),
                   "RESET_STATE": str(root), "RESET_STATUS": status, "RESET_CHOOSER": str(int(chooser)),
                   "RESET_DELAY": str(delay), "RESET_CONTEXT": context, "RESET_PANE_HEIGHT": str(pane_height),
                   "RESET_PREFIX": prefix, "RESET_STARTUP": startup,
                   "RESET_OLD_CONTEXT": old_context, "RESET_READY_BOUNDARY": ready_boundary,
                   "RCLICK_RESET_CONTEXT_SECS": deadline, "RCLICK_RESET_POLL_SECS": poll}
            if use_defaults:
                env.pop("RCLICK_HERDR"); env.pop("RCLICK_SLEEP")
            if herdr_override is not None:
                env["RCLICK_HERDR"] = herdr_override
            if locale:
                env["LC_ALL"] = locale
            if timer_var:
                env[timer_var] = deadline
                if timer_var == "RCLICK_RESET_POLL_SECS":
                    env["RCLICK_RESET_CONTEXT_SECS"] = "2"
            started = time.monotonic()
            result = subprocess.run([str(Path(__file__).with_name("reset.sh")),
                                     "fixture-agent", "fixture-pane"],
                                    capture_output=True, text=True, env=env, timeout=5)
            result.pane_sends = (root / "sends").read_text() if (root / "sends").exists() else ""
            result.pane_gets = int((root / "gets").read_text()) if (root / "gets").exists() else 0
            result.agent_gets = ((root / "agent-gets").read_text().splitlines()
                                 if (root / "agent-gets").exists() else [])
            return result, time.monotonic() - started

    def test_real_saved_screen_with_missing_session_id_succeeds(self):
        result, _ = self.run_screen_reset(context=LIVE_RESET_SCREEN, ready_boundary="", locale="C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_real_codex_0167_fresh_screen_succeeds(self):
        result, _ = self.run_screen_reset(context=LIVE_RESET_SCREEN_0167, ready_boundary="", locale="C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_codex_0167_screen_over_a_prior_transcript_still_fails(self):
        screen = LIVE_RESET_SCREEN_0167.replace("› Ask Codex to do anything", "› hello\n• Hello!\n› Ask Codex to do anything")
        result, _ = self.run_screen_reset(context=screen, ready_boundary="", locale="C", deadline="0.3")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL reset fixture-agent", result.stdout)

    def test_header_over_prior_transcript_never_proves_freshness(self):
        transcripts = ("› hello\n• Hello!", "› hello", "• Ran a tool", "└ tool output",
                       "Previous model reply", "```\nold reply\n```", "> quoted reply",
                       "Tip: old model reply", "› Ask Codex to do anything else", "/tmp/old-model-output")
        for transcript in transcripts:
            for percent in (0, 3):
                with self.subTest(transcript=transcript, percent=percent):
                    screen = LIVE_RESET_SCREEN.replace("› Ask Codex to do anything",
                                                      transcript + "\n› Ask Codex to do anything")
                    screen = screen.replace("Context 0%", f"Context {percent}%")
                    result, _ = self.run_screen_reset(context=screen, ready_boundary="", startup="",
                                               deadline="0.1", locale="C",
                                               session_before="old-session", session_after="old-session")
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_transcript_before_bottommost_footer_revokes_header_proof(self):
        for percent in (0, 3):
            with self.subTest(percent=percent):
                screen = LIVE_RESET_SCREEN + f"› hello\n• Hello!\n› Ask Codex to do anything\nContext {percent}% used"
                result, _ = self.run_screen_reset(context=screen, ready_boundary="", startup="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_short_old_nonzero_screen_waits_for_real_fresh_screen(self):
        old = LIVE_RESET_SCREEN.replace("› Ask Codex to do anything", "› hello\n• Hello!")
        old = old.replace("Context 0%", "Context 3%")
        result, _ = self.run_screen_reset(delay=1, startup=old, context=LIVE_RESET_SCREEN,
                                   ready_boundary="", session_before="old-session", session_after="old-session")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)
        self.assertGreaterEqual(result.pane_gets, 3)

    def test_empty_welcome_screen_allows_known_tips_and_box_art(self):
        screen = LIVE_RESET_SCREEN.replace("› Ask Codex to do anything",
            "╭──╮\n│  │\n╰──╯\n  Tip: Use /help to see available commands.\n› Ask Codex to do anything")
        result, _ = self.run_screen_reset(context=screen, ready_boundary="", locale="C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_changed_session_id_proves_markerless_footer(self):
        result, _ = self.run_screen_reset(session_before="old-session", session_after="new-session", ready_boundary="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_unchanged_session_id_accepts_real_saved_screen(self):
        result, _ = self.run_screen_reset(session_before="old-session", session_after="old-session",
                                   context=LIVE_RESET_SCREEN, ready_boundary="", locale="C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_unchanged_session_id_rejects_stale_screen_without_header(self):
        for screen in ("Context 0% used", "/new\nContext 0% used", "Starting MCP servers\nContext 0% used"):
            with self.subTest(screen=screen):
                result, _ = self.run_screen_reset(session_before="old-session", session_after="old-session",
                                           context=screen, ready_boundary="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_session_id_change_is_polled_before_success(self):
        result, _ = self.run_screen_reset(session_before="old-session", session_after="new-session", session_delay=2, ready_boundary="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)
        self.assertGreaterEqual(result.pane_gets, 4)

    def test_session_id_unavailable_on_either_side_uses_header(self):
        for before, after in (("", "new-session"), ("old-session", "")):
            with self.subTest(before=before, after=after):
                result, _ = self.run_screen_reset(session_before=before, session_after=after,
                                           context=LIVE_RESET_SCREEN, ready_boundary="")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.SUCCESS)

    def test_changed_session_still_requires_footer_and_rejects_nonzero(self):
        for context, expected in (("", "no context line after 0.1s"),
                                  ("Context 12% used", "Context 12% used after /new")):
            with self.subTest(context=context):
                result, _ = self.run_screen_reset(session_before="old-session", session_after="new-session",
                                           context=context, ready_boundary="", startup="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, f"FAIL reset fixture-agent: {expected}\n")

    def test_real_status_line_needs_proof_and_rejects_nonzero(self):
        result, _ = self.run_screen_reset(context=LIVE_RESET_SCREEN.replace("Context 0%", "Context 12%"),
                                   ready_boundary="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: Context 12% used after /new\n")
        footer = LIVE_RESET_SCREEN.splitlines()[-2]
        result, _ = self.run_screen_reset(context=footer, ready_boundary="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_quoted_or_fenced_header_cannot_prove_reset(self):
        for header in ('> >_ OpenAI Codex (v0.166.0)', '" >_ OpenAI Codex (v0.166.0)"',
                       '```\n>_ OpenAI Codex (v0.166.0)\n```'):
            with self.subTest(header=header):
                result, _ = self.run_screen_reset(context=header + "\nContext 0% used", ready_boundary="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_header_must_precede_footer_in_same_read(self):
        for delay, startup, context in ((0, "", "Context 0% used\n>_ OpenAI Codex (v0.166.0)"),
                                         (1, ">_ OpenAI Codex (v0.166.0)", "Context 0% used")):
            with self.subTest(delay=delay):
                result, _ = self.run_screen_reset(delay=delay, startup=startup, context=context,
                                           ready_boundary="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY if delay == 0 else
                                 "FAIL reset fixture-agent: no context line after 0.1s\n")

    def test_changed_id_does_not_accept_footer_under_chooser(self):
        result, _ = self.run_screen_reset(session_before="old-session", session_after="new-session",
                                   prefix="Where should the new conversation run?", ready_boundary="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")

    def test_unchanged_session_id_without_header_waits_on_nonzero_footer(self):
        result, elapsed = self.run_screen_reset(session_before="old-session", session_after="old-session",
                                         context="Context 12% used", ready_boundary="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)
        self.assertGreaterEqual(elapsed, 0.09)

    def test_quoted_or_fenced_decorated_footer_is_ignored(self):
        footer = LIVE_RESET_SCREEN.splitlines()[-2]
        for quoted in ('> ' + footer.strip(), '"' + footer.strip() + '"',
                       'The pane says ' + footer.strip(), '```\n' + footer + '\n```',
                       '~~~\n' + footer + '\n~~~'):
            with self.subTest(quoted=quoted):
                result, _ = self.run_screen_reset(context=quoted, deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_unchanged_id_with_header_uses_bottommost_footer(self):
        for context in ("Context 12% used", "Context 0% used\nContext 12% used"):
            with self.subTest(context=context):
                result, _ = self.run_screen_reset(session_before="old-session", session_after="old-session", context=context)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: Context 12% used after /new\n")

    def test_later_ordering_marker_requires_new_header(self):
        for marker in ("/new", "Starting MCP servers", "Where should the new conversation run?"):
            with self.subTest(marker=marker):
                result, _ = self.run_screen_reset(context=marker + "\nContext 0% used", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")

    def test_empty_startup_reads_preserve_success(self):
        for delay in (0, 1, 3, 12):
            with self.subTest(delay=delay):
                result, _ = self.run_screen_reset(delay=delay)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.SUCCESS)

    def test_done_status_can_reset(self):
        result, _ = self.run_reset(status="done")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_missing_context_waits_for_and_names_timeout(self):
        result, elapsed = self.run_screen_reset(context="", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: no context line after 0.1s\n")
        self.assertGreaterEqual(elapsed, 0.09)

    def test_invalid_timers_fail_before_any_pane_input(self):
        invalid = ("0", "-1", "abc", "", " ", "inf", "Inf", "nan", "NaN", "1e400",
                   "300.01", "999999999999999999999999999999", "1+1", "a[$(exit 91)]")
        for var in ("RCLICK_RESET_CONTEXT_SECS", "RCLICK_RESET_POLL_SECS"):
            for value in invalid:
                with self.subTest(var=var, value=value):
                    result, _ = self.run_reset(deadline=value, timer_var=var)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, f"FAIL reset fixture-agent: invalid {var}={value}\n")
                    self.assertEqual(result.pane_sends, "")

    def test_positive_decimal_timer_boundaries(self):
        for var in ("RCLICK_RESET_CONTEXT_SECS", "RCLICK_RESET_POLL_SECS"):
            for value in ("0.01", "300"):
                with self.subTest(var=var, value=value):
                    result, _ = self.run_reset(deadline=value, timer_var=var)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, self.SUCCESS)

    def test_stale_zero_before_title_cannot_prove_fresh_screen(self):
        for marker in ("Where should the new conversation run?", "/new", "Starting MCP servers (3/4)"):
            with self.subTest(marker=marker):
                result, _ = self.run_screen_reset(delay=3, context="Context 12% used", deadline="0.1",
                                           prefix=f"Context 0% used\n{marker}")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_old_nonzero_above_title_cannot_prove_fresh_screen(self):
        result, _ = self.run_screen_reset(prefix="Context 12% used\n/new", deadline="0.1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_bottommost_new_footer_decides(self):
        result, _ = self.run_screen_reset(context="Context 0% used\nContext 12% used")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: Context 12% used after /new\n")

    def test_quoted_context_in_body_is_ignored(self):
        for quote in ('The issue says "Context 0% used" during startup.', '"Context 0% used"',
                      '> Context 0% used'):
            with self.subTest(quote=quote):
                result, _ = self.run_screen_reset(context="", deadline="0.1", startup=f">_ OpenAI Codex (v0.166.0)\n{quote}")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_markerless_stale_footer_cannot_succeed_early(self):
        result, _ = self.run_screen_reset(old_context="Context 0% used", delay=3, deadline="0.1",
                                   startup="Context 0% used", context="Context 12% used", ready_boundary="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    NO_BOUNDARY = ("FAIL reset fixture-agent: no new-session boundary seen within 0.1s; "
                   "check the pane\n")

    def test_unchanged_markerless_zero_never_proves_reset(self):
        result, _ = self.run_screen_reset(old_context="Context 0% used", deadline="0.1", ready_boundary="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_blank_then_stale_zero_never_proves_reset(self):
        result, _ = self.run_screen_reset(old_context="Context 0% used", delay=1, startup="", deadline="0.1",
                                   ready_boundary="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_boundary_does_not_latch_across_reads(self):
        result, _ = self.run_screen_reset(delay=1, startup="/new", deadline="0.1", ready_boundary="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_footer_under_last_chooser_is_not_session_context(self):
        for context in ("Context 0% used", "Context 37% used"):
            with self.subTest(context=context):
                result, _ = self.run_screen_reset(prefix="/new\nWhere should the new conversation run?",
                                           context=context, ready_boundary="", deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_chooser_footer_waits_for_started_session(self):
        result, _ = self.run_screen_reset(delay=1, startup="Where should the new conversation run?\nContext 37% used")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_non_header_boundaries_never_prove_session_in_c_locale(self):
        for boundary in ("/new", "> /new", "❯ /new", "› /new", "Starting MCP servers (3/4)"):
            for context in ("Context 0% used", "Context 12% used"):
                with self.subTest(boundary=boundary, context=context):
                    result, _ = self.run_screen_reset(ready_boundary=boundary, locale="C", context=context, deadline="0.1")
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_quoted_boundaries_never_prove_reset(self):
        for boundary in ('> /new', '> Starting MCP servers (3/4)',
                         '> Where should the new conversation run?', '"Starting MCP servers (3/4)"'):
            # > /new is a real Codex prompt; blockquoted startup/chooser text is not.
            if boundary == '> /new':
                continue
            with self.subTest(boundary=boundary):
                result, _ = self.run_screen_reset(ready_boundary=boundary, deadline="0.1")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_fenced_context_quote_is_ignored(self):
        for fence in ("```", "~~~"):
            with self.subTest(fence=fence):
                result, _ = self.run_screen_reset(context="", deadline="0.1",
                                           startup=f">_ OpenAI Codex (v0.166.0)\n{fence}text\nContext 0% used\n{fence}\nStill starting")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_fenced_reset_marker_does_not_freshen_stale_footer(self):
        result, _ = self.run_screen_reset(old_context="Context 0% used", deadline="0.1",
                                   context="Context 0% used\n```\n/new\n```", ready_boundary="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.NO_BOUNDARY)

    def test_nonzero_context_fails_even_after_startup(self):
        for delay in (0, 3):
            with self.subTest(delay=delay):
                result, _ = self.run_screen_reset(delay=delay, context="Context 12% used")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "FAIL reset fixture-agent: Context 12% used after /new\n")

    def test_reset_reads_the_pane_while_the_name_does_not_resolve(self):
        # #107: the name is only a label; status and the old session come from `herdr agent get <pane>`.
        result, _ = self.run_reset()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)
        self.assertTrue(result.agent_gets)
        self.assertEqual(set(result.agent_gets), {"fixture-pane"})

    def test_reset_honors_explicit_herdr_and_keeps_path_defaults(self):
        result, _ = self.run_reset(status="busy", herdr_override="/usr/bin/false")
        self.assertIn("cannot read pane fixture-pane", result.stdout)
        self.assertEqual(result.pane_sends, "")
        result, _ = self.run_reset(use_defaults=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_timeout_elapsed_is_virtual(self):
        result, elapsed = self.run_screen_reset(context="", deadline="0.1", poll="0.025")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(elapsed, 0.1)

    def test_busy_status_refuses_reset(self):
        result, _ = self.run_reset(status="busy")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: pane fixture-pane status busy, not idle\n")
        self.assertEqual(result.pane_sends, "")

    def test_failed_pane_lookup_names_the_real_cause(self):
        cases = (
            ('{"error":{"code":"agent_not_found","message":"agent target fixture-pane not found"},'
             '"id":"cli:agent:get"}', 1, "agent target fixture-pane not found"),
            ("herdr: cannot connect to server socket", 1, "herdr: cannot connect to server socket"),
            ('{"result":{"type":"agent_info"}}', 0, "no agent_status in herdr agent get output"),
        )
        for output, code, cause in cases:
            with self.subTest(cause=cause):
                result, _ = self.run_reset(agent_get=output, agent_get_exit=code)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, f"FAIL reset fixture-agent: cannot read pane fixture-pane: {cause}\n")
                self.assertEqual(result.pane_sends, "")

    def test_missing_chooser_fails(self):
        result, _ = self.run_reset(chooser=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FAIL reset fixture-agent: chooser never appeared\n")


class ResetFreshScreenTests(unittest.TestCase):
    """#434: welcome-like transcript must not re-prove a stale screen."""

    run_reset = run_screen_reset
    SUCCESS = ResetTests.SUCCESS
    NO_BOUNDARY = ResetTests.NO_BOUNDARY
    SCREEN = Path(__file__).with_name("fixtures").joinpath("reset-fresh-codex.txt").read_text()

    def assert_stale(self, screen, expected=None):
        result, _ = self.run_reset(context=screen, ready_boundary="", startup="",
                                   deadline="0.1", locale="C",
                                   session_before="old-session", session_after="old-session")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, expected or self.NO_BOUNDARY)

    def test_embedded_title_does_not_erase_transcript(self):
        self.assert_stale(self.SCREEN.replace("› Ask Codex to do anything",
            "› hello\n• Hello!\n>_ OpenAI Codex (v0.166.0)\n› Ask Codex to do anything"))

    def test_old_placeholder_only_transcript_is_not_fresh(self):
        self.assert_stale(self.SCREEN.replace("› Ask Codex to do anything",
            "› Ask Codex to do anything\n› Ask Codex to do anything"))

    def test_old_welcome_tip_only_transcript_is_not_fresh(self):
        self.assert_stale(self.SCREEN.replace("› Ask Codex to do anything",
            "› Ask Codex to do anything\nTip: Use /help to see available commands."))

    def test_old_box_art_only_transcript_is_not_fresh(self):
        self.assert_stale(self.SCREEN.replace("› Ask Codex to do anything",
            "› Ask Codex to do anything\n╭──╮\n│  │\n╰──╯"))

    def test_saved_real_fresh_screen_passes(self):
        for screen in (self.SCREEN, self.SCREEN.replace("\n", "\r\n")):
            with self.subTest(crlf="\r" in screen):
                result, _ = self.run_reset(context=screen, ready_boundary="", locale="C",
                                           session_before="old-session", session_after="old-session")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.SUCCESS)

    def test_title_directly_after_leading_cwd_metadata_passes(self):
        screen = "\n~/fixture-worktree\n" + self.SCREEN.lstrip()
        result, _ = self.run_reset(context=screen, ready_boundary="", locale="C")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_old_scrollback_above_complete_fresh_header_passes(self):
        self.assert_fresh("old transcript\nContext 12% used\n" + self.SCREEN)

    def assert_fresh(self, screen, **kwargs):
        result, _ = self.run_reset(context=screen, ready_boundary="", locale="C",
                                   session_before="old-session", session_after="old-session", deadline="0.1", **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_new_echo_above_fresh_header_passes(self):
        self.assert_fresh("› /new\n" + self.SCREEN)

    def test_chooser_above_fresh_header_passes(self):
        self.assert_fresh("Where should the new conversation run?\n1. Use current Git worktree\n" + self.SCREEN)

    def test_footer_hints_between_placeholder_and_footer_pass(self):
        for hint in ("? for shortcuts", "? for help", "? for commands"):
            with self.subTest(hint=hint):
                self.assert_fresh(self.SCREEN.replace("› Ask Codex to do anything",
                                                     "› Ask Codex to do anything\n" + hint))

    def test_twenty_five_row_pane_read_reaches_fresh_title(self):
        self.assertGreater(len(self.SCREEN.splitlines()), 25)
        result, _ = ResetTests.run_reset(self, context=self.SCREEN, ready_boundary="", pane_height=25)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_last_title_with_dirty_body_revokes_earlier_fresh_screen(self):
        self.assert_stale(self.SCREEN + "\n>_ OpenAI Codex (v0.166.0)\n~/fixture-worktree\n› old prompt\nContext 0% used")

    def test_cwd_metadata_rejects_slash_commands_and_spaces(self):
        for cwd in ("/new", "/help", "/tmp/old output", "~/old output"):
            with self.subTest(cwd=cwd):
                self.assert_stale(self.SCREEN.replace("~/fixture-worktree", cwd),
                    expected="FAIL reset fixture-agent: no context line after 0.1s\n" if cwd == "/new" else None)

    def test_cwd_metadata_accepts_absolute_path(self):
        self.assert_fresh(self.SCREEN.replace("~/fixture-worktree", "/tmp/fixture-worktree"))


class ResetShortScreenTests(unittest.TestCase):
    """#468: compact replays derived from the saved real Codex pane, not raw captures."""

    run_reset = run_screen_reset
    SUCCESS = ResetTests.SUCCESS
    NO_BOUNDARY = ResetTests.NO_BOUNDARY
    NO_CONTEXT = "FAIL reset fixture-agent: no context line after 0.1s\n"
    RESIDUE = ("• Previous reply\n› /new\nWhere should the new conversation run?\n"
               "› 1. Use current Git worktree\n")
    # Derived input, not a raw capture: the saved real fixture's last 25 rows,
    # including every blank. Title and cwd are outside this contiguous short read.
    SHORT_DERIVED = Path(__file__).with_name("fixtures").joinpath("reset-fresh-codex-short-derived.txt").read_text()
    # Synthetic residue is a separate adversarial input, not captured pane history.
    TITLELESS = RESIDUE + SHORT_DERIVED
    LOGO = "\n".join(line for line in SHORT_DERIVED.splitlines()
                      if any("\u2800" <= c <= "\u28ff" for c in line))

    def replay(self, screen, **kwargs):
        return self.run_reset(context=screen, ready_boundary="", startup="", deadline="0.1",
                              locale="C", session_before="old-session", session_after="old-session", **kwargs)

    def assert_rejected(self, screen, expected=None):
        result, _ = self.replay(screen)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, expected or self.NO_BOUNDARY)

    def test_derived_contiguous_short_read_with_or_without_synthetic_residue_passes(self):
        self.assertEqual(len(self.SHORT_DERIVED.splitlines()), 25)
        self.assertEqual(self.SHORT_DERIVED, "\n".join(LIVE_RESET_SCREEN.splitlines()[-25:]) + "\n")
        for screen in (self.SHORT_DERIVED, self.TITLELESS):
            for identity in ("", "old-session"):
                with self.subTest(residue=screen == self.TITLELESS, identity=identity):
                    result, _ = self.run_reset(context=screen, ready_boundary="", startup="", deadline="0.1",
                                               locale="C", session_before=identity, session_after=identity)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, self.SUCCESS)

    def test_output_after_zero_footer_revokes_context_in_both_suffix_orders(self):
        for screen in (self.SHORT_DERIVED, self.TITLELESS, LIVE_RESET_SCREEN):
            for suffix in ("› hello", "• Previous reply", "› hello\n• Previous reply", "• Previous reply\n› hello"):
                with self.subTest(residue=screen == self.TITLELESS, suffix=suffix):
                    self.assert_rejected(screen + "\n" + suffix)

    def test_dirty_suffix_after_footer_hints_cannot_restore_zero_footer(self):
        for suffix in ("› hello", "• Previous reply", "╭──╮", "› Ask Codex to do anything", "```\nold reply\n```"):
            with self.subTest(suffix=suffix):
                self.assert_rejected(self.TITLELESS + "\n? for help\n\n" + suffix + "\nContext 0% used")

    def test_disallowed_suffix_before_allowed_hints_still_revokes_context(self):
        for suffix in ("› hello", "• Previous reply"):
            with self.subTest(suffix=suffix):
                self.assert_rejected(self.SHORT_DERIVED + "\n" + suffix + "\n? for help\n\n")

    def test_allowed_hints_and_blanks_after_final_footer_stay_fresh(self):
        result, _ = self.replay(self.SHORT_DERIVED + "\n? for help\n? for commands\n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_older_header_separated_from_titleless_logo_is_scrollback(self):
        old = LIVE_RESET_SCREEN.replace("Context 0%", "Context 12%")
        for boundary in ("› /new\n", "Where should the new conversation run?\n1. Use current Git worktree\n", ""):
            with self.subTest(boundary=boundary):
                result, _ = self.replay(old + "\n" + boundary + self.SHORT_DERIVED)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.SUCCESS)

    def test_opus_trace_old_header_echo_chooser_new_logo_passes(self):
        old_header = LIVE_RESET_SCREEN.split("› Ask Codex to do anything")[0]
        result, _ = self.replay(old_header + self.RESIDUE + self.SHORT_DERIVED)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_later_title_or_dirty_earlier_header_still_vetoes_logo(self):
        self.assert_rejected(self.SHORT_DERIVED + "\n>_ OpenAI Codex (v0.166.0)\n› pending\nContext 0% used")
        for dirty in ("• Previous reply", "/help", "/tmp/old output"):
            with self.subTest(dirty=dirty):
                self.assert_rejected(">_ OpenAI Codex (v0.166.0)\n" + dirty + "\n› /new\n" + self.SHORT_DERIVED)

    def test_changed_identity_remains_independent_of_logo_placeholder(self):
        screen = self.TITLELESS.replace("› Ask Codex to do anything", "")
        result, _ = self.run_reset(context=screen, ready_boundary="", startup="", deadline="0.1",
                                   locale="C", session_before="old-session", session_after="new-session")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_changed_identity_accepts_logo_without_placeholder_or_residue(self):
        screen = self.TITLELESS.removeprefix(self.RESIDUE).replace("› Ask Codex to do anything", "")
        result, _ = self.run_reset(context=screen, ready_boundary="", startup="", deadline="0.1",
                                   locale="C", session_before="old-session", session_after="new-session")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.SUCCESS)

    def test_logo_candidate_does_not_hide_dirty_suffix(self):
        for screen in (self.TITLELESS,):
            for transcript in ("› hello\n• Hello!\n› Ask Codex to do anything",
                               "› Ask Codex to do anything\n• Previous reply",
                               "› Ask Codex to do anything\n› Ask Codex to do anything"):
                with self.subTest(title="OpenAI Codex" in screen, transcript=transcript):
                    self.assert_rejected(screen.replace("› Ask Codex to do anything", transcript))

    def test_logo_fallback_requires_full_logo_and_one_placeholder(self):
        for screen in (self.TITLELESS,):
            for logo in ("╭──╮\n│  │\n╰──╯", "\n".join(self.LOGO.splitlines()[:-1]), ""):
                with self.subTest(title="OpenAI Codex" in screen, logo=logo):
                    self.assert_rejected(screen.replace(self.LOGO, logo))
            with self.subTest(title="OpenAI Codex" in screen, placeholder=False):
                self.assert_rejected(screen.replace("› Ask Codex to do anything", ""), self.NO_CONTEXT)

    def test_quoted_or_fenced_logo_cannot_prove_freshness(self):
        for screen in (self.TITLELESS,):
            for quoted in ("\n".join("> " + line for line in screen.splitlines()),
                           "```\n" + screen + "\n```", "~~~\n" + screen + "\n~~~"):
                with self.subTest(title="OpenAI Codex" in screen, quoted=quoted[:20]):
                    self.assert_rejected(quoted)

    def test_logo_cannot_erase_dirty_metadata_below_latest_title(self):
        for content in ("• Previous reply", "/help", "/tmp/old output", "~/old output"):
            with self.subTest(content=content):
                screen = self.RESIDUE + ">_ OpenAI Codex (v0.166.0)\n" + content + "\n" + self.SHORT_DERIVED
                self.assert_rejected(screen)

    def test_later_marker_revokes_logo_context(self):
        for screen in (self.TITLELESS,):
            for marker in ("Where should the new conversation run?", "Starting MCP servers (3/4)", "› /new"):
                with self.subTest(title="OpenAI Codex" in screen, marker=marker):
                    self.assert_rejected(screen.replace("› Ask Codex to do anything",
                                                        "› Ask Codex to do anything\n" + marker), self.NO_CONTEXT)

    def test_logo_requires_bottommost_zero_footer(self):
        for screen in (self.TITLELESS,):
            footer = next(line for line in screen.splitlines() if "Context 0% used" in line)
            for suffix, expected in (("", self.NO_CONTEXT),
                                     (footer.replace("Context 0%", "Context 12%"),
                                      "FAIL reset fixture-agent: Context 12% used after /new\n"),
                                     (footer + "\nContext 12% used",
                                      "FAIL reset fixture-agent: Context 12% used after /new\n"),
                                     (footer + "\n› hello\n• Hello!\nContext 0% used", self.NO_BOUNDARY)):
                with self.subTest(title="OpenAI Codex" in screen, suffix=suffix):
                    self.assert_rejected(screen.replace(footer, suffix), expected)

    def test_logo_proof_and_footer_cannot_cross_reads_in_either_order(self):
        candidate = "\n".join(line for line in self.TITLELESS.splitlines() if "Context 0% used" not in line)
        for startup, context in ((candidate, "Context 0% used"), ("Context 0% used", candidate)):
            with self.subTest(logo_first=startup == candidate):
                result, _ = self.run_reset(delay=1, startup=startup, context=context,
                                           ready_boundary="", deadline="0.1", locale="C",
                                           session_before="old-session", session_after="old-session")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, self.NO_CONTEXT)
                self.assertGreaterEqual(result.pane_gets, 3)

class OwnerGatesTests(unittest.TestCase):
    """owner-gates.sh refuses to start on a nearly full disk (#34) and otherwise runs scripts/gates.sh."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.repo, self.out = root / "repo", root / "gates"
        self.repo.mkdir()
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
                    "RCLICK_GATES_OUT": str(self.out), "TMPDIR": str(root)}
        git(self.repo, "init", "-q", "-b", "main", env=self.env)
        (self.repo / "scripts").mkdir()
        self.root = root
        self.marker = root / "gates-ran"
        self.commit_gates("echo 'GATE build PASS'\necho 'GATE unit-tests PASS'\necho 'GATE localization SKIP no catalogs'\n"
                          "echo 'GATE skill-tooling PASS'\necho 'GATES PASS'\n")

    def commit_gates(self, body, exit_code=0):
        gates = self.repo / "scripts/gates.sh"
        # The marker proves whether the gates lane ran at all.
        gates.write_text(f"#!/bin/sh\ntouch '{self.root}/gates-ran'\n{body}exit {exit_code}\n")
        gates.chmod(0o755)
        git(self.repo, "add", "scripts/gates.sh", env=self.env)
        git(self.repo, "commit", "-qm", "gates", env=self.env)
        self.sha = git(self.repo, "rev-parse", "HEAD").strip()

    def tearDown(self):
        self.tmp.cleanup()

    def run_gates(self, min_free_gib):
        env = {**self.env, "RCLICK_GATES_MIN_FREE_GIB": min_free_gib}
        return subprocess.run([str(Path(__file__).with_name("owner-gates.sh")), str(self.repo), self.sha, "t99-r1"],
                              capture_output=True, text=True, env=env)

    def summary(self):
        return (self.out / "t99-r1-summary.txt").read_text()

    def test_refuses_to_start_below_the_free_space_minimum(self):
        result = self.run_gates("999999")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        summary = self.summary()
        self.assertIn("refused: low disk", summary)
        self.assertIn("free space first", summary)
        self.assertTrue(summary.rstrip().endswith("DONE overall=1"), summary)
        self.assertNotIn("lane gates", summary)
        self.assertFalse(self.marker.exists(), "gates.sh must not run on a nearly full disk")

    def test_runs_the_gates_and_copies_the_lane_lines(self):
        result = self.run_gates("0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        summary = self.summary()
        self.assertIn("lane gates rc=0", summary)
        self.assertIn("GATE unit-tests PASS", summary)
        self.assertIn("GATE localization SKIP no catalogs", summary)
        self.assertIn("GATES PASS", summary)
        self.assertTrue(summary.rstrip().endswith("DONE overall=0"), summary)
        self.assertTrue(self.marker.exists())

    def test_a_failed_lane_fails_the_run(self):
        self.commit_gates("echo 'GATE build PASS'\necho 'GATE unit-tests FAIL'\necho 'GATES FAIL'\n", exit_code=1)
        result = self.run_gates("0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        summary = self.summary()
        self.assertIn("lane gates rc=1", summary)
        self.assertIn("GATE unit-tests FAIL", summary)
        self.assertTrue(summary.rstrip().endswith("DONE overall=1"), summary)

    def test_exit_zero_without_gates_pass_is_not_a_pass(self):
        self.commit_gates("echo 'GATE build PASS'\n")
        result = self.run_gates("0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("no 'GATES PASS' line", self.summary())

    def test_missing_gate_script_fails(self):
        git(self.repo, "rm", "-q", "scripts/gates.sh", env=self.env)
        git(self.repo, "commit", "-qm", "drop", env=self.env)
        self.sha = git(self.repo, "rev-parse", "HEAD").strip()
        result = self.run_gates("0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("scripts/gates.sh missing", self.summary())

    # #17: a failed lane's own log (.build/gates/<lane>.log in the scratch tree) is kept before the scratch is removed.
    TRACEBACK = ("Traceback (most recent call last):\n  File \"test_delegator_scripts.py\", line 9, in test_x\n"
                 "subprocess.TimeoutExpired: Command 'zsh' timed out after 5 seconds\n")

    @staticmethod
    def write_lane_log(lane, text):
        # The fake gates.sh runs in the scratch tree, like the real one, and writes the lane log where gates.sh does.
        return f"mkdir -p .build/gates\ncat > .build/gates/{lane}.log <<'EOF'\n{text}EOF\n"

    def failure_log(self, lane):
        return self.out / f"t99-r1-{lane}-failure.log"

    def test_a_failed_lane_keeps_its_own_log_with_a_load_header(self):
        self.commit_gates(self.write_lane_log("skill-tooling", "### python -m unittest x\n" + self.TRACEBACK)
                          + "echo 'GATE build PASS'\necho 'GATE skill-tooling FAIL (1 of 3 test files)'\n"
                            "echo '  .agents/skills/rclick-delegator/scripts/test_delegator_scripts.py'\n"
                            "echo 'GATES FAIL'\n", exit_code=1)
        result = self.run_gates("0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        summary = self.summary()
        self.assertTrue(summary.rstrip().endswith("DONE overall=1"), summary)
        kept = self.failure_log("skill-tooling")
        self.assertIn(f"lane skill-tooling failure-log={kept}\n", summary)
        text = kept.read_text()
        header, _, body = text.partition("\n---\n")
        self.assertIn(f"commit: {self.sha}", header)
        self.assertIn("lane: skill-tooling", header)
        self.assertRegex(header, r"(?m)^loadavg: \S")
        self.assertRegex(header, r"(?m)^ncpu: \S")
        self.assertRegex(header, r"(?m)^uptime: \S")
        self.assertIn("GATE skill-tooling FAIL (1 of 3 test files)", header)
        self.assertIn(".agents/skills/rclick-delegator/scripts/test_delegator_scripts.py", header)
        self.assertIn(self.TRACEBACK, body)

    def test_the_load_header_trims_linux_uptime_and_survives_a_missing_sysctl(self):
        # Linux uptime starts with a space; Linux has no vm.loadavg / hw.ncpu sysctl (seen on the Linux preflight).
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, body in (("uptime", "echo ' 06:23:55 up 264 days,  load average: 0.03, 0.04, 0.01'"),
                           ("sysctl", "echo 'sysctl: unknown oid' >&2; exit 1")):
            (bin_dir / name).write_text(f"#!/bin/sh\n{body}\n")
            (bin_dir / name).chmod(0o755)
        self.env["PATH"] = f"{bin_dir}:{self.env['PATH']}"
        self.commit_gates(self.write_lane_log("skill-tooling", self.TRACEBACK)
                          + "echo 'GATE skill-tooling FAIL (1 of 3 test files)'\necho 'GATES FAIL'\n", exit_code=1)
        result = self.run_gates("0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(self.summary().rstrip().endswith("DONE overall=1"), self.summary())
        header = self.failure_log("skill-tooling").read_text().partition("\n---\n")[0]
        self.assertIn("\nuptime: 06:23:55 up 264 days,  load average: 0.03, 0.04, 0.01\n", header)
        self.assertIn("\nloadavg: unavailable\n", header)
        self.assertIn("\nncpu: unavailable\n", header)

    def test_a_failed_lane_without_a_lane_log_is_reported_not_a_crash(self):
        self.commit_gates("echo 'GATE skill-tooling FAIL (1 of 3 test files)'\necho 'GATES FAIL'\n", exit_code=1)
        result = self.run_gates("0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        summary = self.summary()
        self.assertTrue(summary.rstrip().endswith("DONE overall=1"), summary)
        self.assertIn("lane skill-tooling failure-log=none reason=no .build/gates/skill-tooling.log", summary)
        self.assertFalse(self.failure_log("skill-tooling").exists())

    def test_a_long_lane_log_keeps_only_its_last_3000_lines(self):
        self.commit_gates("mkdir -p .build/gates\nseq 1 5000 | sed 's/^/line /' > .build/gates/build.log\n"
                          "echo 'GATE build FAIL (exit 65)'\necho 'GATES FAIL'\n", exit_code=1)
        result = self.run_gates("0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        header, _, body = self.failure_log("build").read_text().partition("\n---\n")
        self.assertIn("truncated: kept the last 3000 of 5000 lines", header)
        lines = body.splitlines()
        self.assertEqual(len(lines), 3000)
        self.assertEqual((lines[0], lines[-1]), ("line 2001", "line 5000"))

    def test_a_short_lane_log_is_kept_whole(self):
        self.commit_gates(self.write_lane_log("build", "line 1\nline 2\n")
                          + "echo 'GATE build FAIL (exit 65)'\necho 'GATES FAIL'\n", exit_code=1)
        self.run_gates("0")
        header, _, body = self.failure_log("build").read_text().partition("\n---\n")
        self.assertIn("truncated: no (2 lines)", header)
        self.assertEqual(body, "line 1\nline 2\n")

    def test_a_passing_run_keeps_no_failure_log(self):
        self.commit_gates(self.write_lane_log("skill-tooling", "ok\n") + self.write_lane_log("build", "ok\n")
                          + "echo 'GATE build PASS'\necho 'GATE skill-tooling PASS (3 test files)'\necho 'GATES PASS'\n")
        result = self.run_gates("0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("failure-log=", self.summary())
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ["t99-r1-gates.log", "t99-r1-summary.txt"])

    def test_two_failed_lanes_keep_two_logs(self):
        self.commit_gates(self.write_lane_log("unit-tests", "unit failure\n")
                          + self.write_lane_log("skill-tooling", self.TRACEBACK)
                          + "echo 'GATE build PASS'\necho 'GATE unit-tests FAIL (exit 65; tests: 3 passed, 1 failed)'\n"
                            "echo 'GATE localization PASS'\necho 'GATE skill-tooling FAIL (1 of 3 test files)'\n"
                            "echo 'GATES FAIL'\n", exit_code=1)
        result = self.run_gates("0")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        summary = self.summary()
        for lane, text in (("unit-tests", "unit failure\n"), ("skill-tooling", self.TRACEBACK)):
            self.assertIn(f"lane {lane} failure-log={self.failure_log(lane)}\n", summary)
            self.assertTrue(self.failure_log(lane).read_text().endswith("---\n" + text), lane)
        self.assertEqual(summary.count("failure-log="), 2, summary)
        self.assertTrue(summary.rstrip().endswith("DONE overall=1"), summary)

    def test_the_scratch_tree_is_removed_after_a_failing_run(self):
        self.commit_gates(self.write_lane_log("skill-tooling", self.TRACEBACK)
                          + "echo 'GATE skill-tooling FAIL (1 of 3 test files)'\necho 'GATES FAIL'\n", exit_code=1)
        self.run_gates("0")
        self.assertTrue(self.failure_log("skill-tooling").exists())
        self.assertEqual(list(self.root.glob("rclick-gates.*")), [])


class CodexNoQuestionsTests(unittest.TestCase):
    """Codex panes must not stall on a sub-agent question nobody watches."""

    root = Path(__file__).resolve().parent.parent

    def read(self, rel):
        return (self.root / rel).read_text()

    def test_every_codex_start_command_disables_sub_agents(self):
        starts = [line for line in self.read("references/guide.md").splitlines()
                  if "herdr agent start" in line and "--kind codex" in line]
        self.assertEqual(len(starts), 2, starts)
        for line in starts:
            self.assertIn("--disable multi_agent", line)

    def test_brief_and_audit_request_templates_carry_the_no_questions_rule(self):
        for rel in ("references/templates/brief-template.md",
                    "references/templates/audit-request-template.md"):
            text = self.read(rel)
            self.assertIn("No questions in the pane", text, rel)
            self.assertIn("BLOCKED: <reason>", text, rel)


class ListenerStatusEveryTurnTests(unittest.TestCase):
    """A held listener notice is only found by checking status: the skill must say so in the loop."""

    root = Path(__file__).resolve().parent.parent

    def test_skill_requires_status_in_every_turn(self):
        text = (self.root / "SKILL.md").read_text()
        self.assertIn("listen-notify.py status` in every turn and before you end one", text)
        self.assertIn("deferred-user-typing", text)

    def test_guide_lists_the_deferred_typing_symptom(self):
        rows = [line for line in (self.root / "references/guide.md").read_text().splitlines()
                if line.startswith("| A handoff sat for hours with no listener event")]
        self.assertEqual(len(rows), 1)
        self.assertIn("deferred-user-typing", rows[0])


if __name__ == "__main__":
    unittest.main()
