import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "src-tauri" / "agent" / "deep_agent.py"


def load_deep_agent_module():
    spec = importlib.util.spec_from_file_location("deep_agent_under_test", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


deep_agent = load_deep_agent_module()


class DeepAgentSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.temp_root = Path(self.tempdir.name)
        self.allowed_root = self.temp_root / "allowed"
        self.allowed_root.mkdir()
        self.outside_root = self.temp_root / "outside"
        self.outside_root.mkdir()

    def patch_env(self, **overrides):
        env = {
            "DEEP_AGENT_READ_SCOPE": "roots",
            "DEEP_AGENT_ALLOWED_READ_ROOTS": str(self.allowed_root),
            "DEEP_AGENT_ALLOWED_WRITE_ROOTS": str(self.allowed_root),
            "DEEP_AGENT_BLOCK_DESTRUCTIVE_COMMANDS": "true",
            "DEEP_AGENT_TOOL_OUTPUT_CHAR_LIMIT": "12000",
            "DEEP_AGENT_LIST_FILES_MAX_ENTRIES": "200",
        }
        env.update(overrides)
        return mock.patch.dict(os.environ, env, clear=False)

    def test_assert_read_allowed_allows_paths_inside_configured_roots(self):
        target = self.allowed_root / "notes.txt"

        with self.patch_env():
            resolved = deep_agent._assert_read_allowed(str(target))

        self.assertEqual(resolved, target.resolve(strict=False))

    def test_assert_read_allowed_blocks_paths_outside_configured_roots(self):
        target = self.outside_root / "secret.txt"

        with self.patch_env():
            with self.assertRaises(PermissionError) as ctx:
                deep_agent._assert_read_allowed(str(target))

        self.assertIn("Read access denied outside allowed roots", str(ctx.exception))

    def test_assert_write_allowed_allows_new_files_inside_configured_roots(self):
        target = self.allowed_root / "nested" / "draft.txt"

        with self.patch_env():
            resolved = deep_agent._assert_write_allowed(str(target))

        self.assertEqual(resolved, target.resolve(strict=False))

    def test_assert_write_allowed_blocks_paths_outside_configured_roots(self):
        target = self.outside_root / "draft.txt"

        with self.patch_env():
            with self.assertRaises(PermissionError) as ctx:
                deep_agent._assert_write_allowed(str(target))

        self.assertIn("Write access denied outside allowed roots", str(ctx.exception))

    def test_blocked_shell_reason_detects_blocked_binary_after_env_prefix(self):
        with self.patch_env():
            reason = deep_agent._blocked_shell_reason("DEBUG=1 python3 -c 'print(1)'")

        self.assertIn("python3", reason)

    def test_blocked_shell_reason_detects_destructive_git_subcommands(self):
        with self.patch_env():
            reason = deep_agent._blocked_shell_reason("git restore README.md")

        self.assertIn("restore", reason)

    def test_blocked_shell_reason_allows_benign_commands_when_policy_disabled(self):
        with self.patch_env(DEEP_AGENT_BLOCK_DESTRUCTIVE_COMMANDS="false"):
            reason = deep_agent._blocked_shell_reason("python3 -c 'print(1)'")

        self.assertIsNone(reason)

    def test_limit_tool_output_truncates_and_reports_omitted_characters(self):
        with self.patch_env(DEEP_AGENT_TOOL_OUTPUT_CHAR_LIMIT="10"):
            result = deep_agent._limit_tool_output("123456789012345", label="Shell output")

        self.assertEqual(result, "1234567890\n... [Shell output truncated by 5 characters]")

    def test_shell_blocks_output_redirection(self):
        with self.patch_env():
            result = deep_agent.shell.func("echo hi > out.txt")

        self.assertIn("Blocked by safety policy", result)
        self.assertIn("Shell output redirection is blocked", result)

    def test_shell_rejects_workdirs_outside_read_roots(self):
        with self.patch_env():
            result = deep_agent.shell.func("pwd", workdir=str(self.outside_root))

        self.assertIn("Read access denied outside allowed roots", result)

    def test_shell_truncates_large_output(self):
        with self.patch_env(DEEP_AGENT_TOOL_OUTPUT_CHAR_LIMIT="10"):
            result = deep_agent.shell.func("printf '123456789012345'")

        self.assertEqual(result, "1234567890\n... [Shell output truncated by 5 characters]")

    def test_read_file_returns_numbered_lines_for_allowed_files(self):
        target = self.allowed_root / "example.txt"
        target.write_text("alpha\nbeta\ngamma\n", encoding="utf-8")

        with self.patch_env():
            result = deep_agent.read_file.func(str(target), start_line=2, end_line=2)

        self.assertIn(f"--- {target.resolve(strict=False)} (lines 2-2 of 3) ---", result)
        self.assertIn("     2\tbeta", result)

    def test_write_file_returns_permission_message_for_blocked_path(self):
        target = self.outside_root / "blocked.txt"

        with self.patch_env():
            result = deep_agent.write_file.func(str(target), "hello")

        self.assertIn("write access is blocked", result)

    def test_list_files_enforces_max_entries(self):
        for name in ("a.txt", "b.txt", "c.txt"):
            (self.allowed_root / name).write_text(name, encoding="utf-8")

        with self.patch_env(DEEP_AGENT_LIST_FILES_MAX_ENTRIES="2"):
            result = deep_agent.list_files.func(str(self.allowed_root), recursive=False)

        self.assertIn("a.txt", result)
        self.assertIn("b.txt", result)
        self.assertIn("truncated after 2 entries", result)
        self.assertNotIn("c.txt", result)

    def test_search_files_returns_relative_matches(self):
        docs_dir = self.allowed_root / "docs"
        docs_dir.mkdir()
        (docs_dir / "notes.txt").write_text("Alpha\nbeta\nalpha again\n", encoding="utf-8")

        with self.patch_env():
            result = deep_agent.search_files.func(
                "alpha",
                directory=str(self.allowed_root),
                file_glob="*.txt",
                max_results=5,
            )

        self.assertIn("Found 2 matches (showing 2)", result)
        self.assertIn("docs/notes.txt:1: Alpha", result)
        self.assertIn("docs/notes.txt:3: alpha again", result)


class DeepAgentStreamingTests(unittest.IsolatedAsyncioTestCase):
    async def test_stream_agent_response_uses_top_level_tool_names(self):
        class FakeChunk:
            def __init__(self, content):
                self.content = content

        class FakeAgent:
            async def astream_events(self, *_args, **_kwargs):
                yield {
                    "event": "on_tool_start",
                    "name": "shell",
                    "data": {"input": {"command": "pwd"}},
                    "run_id": "run-1",
                }
                yield {
                    "event": "on_tool_end",
                    "name": "shell",
                    "data": {"output": "ok"},
                    "run_id": "run-1",
                }
                yield {
                    "event": "on_chat_model_stream",
                    "data": {"chunk": FakeChunk("hello")},
                }

        output = io.StringIO()
        with (
            mock.patch.object(deep_agent, "build_agent", return_value=FakeAgent()),
            mock.patch.object(deep_agent, "create_agent", object()),
            mock.patch.object(deep_agent, "_HAS_LEGACY_AGENT", False),
            redirect_stdout(output),
        ):
            await deep_agent._stream_agent_response("hi")

        events = [json.loads(line) for line in output.getvalue().splitlines()]

        self.assertEqual(events[0]["type"], "tool_call")
        self.assertEqual(events[0]["tool"], "shell")
        self.assertEqual(events[1]["type"], "tool_result")
        self.assertEqual(events[1]["tool"], "shell")
        self.assertEqual(events[2], {"type": "chunk", "content": "hello"})
        self.assertEqual(events[3], {"type": "done"})

    async def test_stream_agent_response_emits_error_events_without_exiting(self):
        output = io.StringIO()
        with mock.patch.object(deep_agent, "build_agent", side_effect=RuntimeError("boom")), redirect_stdout(output):
            await deep_agent._stream_agent_response("hi")

        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(events, [{"type": "error", "content": "boom"}])


class DeepAgentAutomationToolTests(unittest.TestCase):
    def test_browser_tool_uses_configured_command(self):
        completed = subprocess_completed(stdout="snapshot ok")

        with (
            mock.patch.object(deep_agent, "_resolve_browser_command", return_value="/usr/local/bin/agent-browser"),
            mock.patch.object(deep_agent.subprocess, "run", return_value=completed) as run_mock,
        ):
            result = deep_agent.browser.func("snapshot -i", timeout=45)

        self.assertIn("snapshot ok", result)
        run_mock.assert_called_once()
        args = run_mock.call_args.args[0]
        self.assertEqual(args[:3], ["/usr/local/bin/agent-browser", "snapshot", "-i"])
        self.assertEqual(run_mock.call_args.kwargs["timeout"], 45)

    def test_browser_tool_reports_missing_command(self):
        with mock.patch.object(deep_agent, "_resolve_browser_command", return_value=None):
            result = deep_agent.browser.func("open https://example.com")

        self.assertIn("Browser automation is unavailable", result)

    def test_list_applications_filters_matches(self):
        with mock.patch.object(
            deep_agent,
            "_find_matching_applications",
            return_value=[Path("/Applications/Google Chrome.app")],
        ), mock.patch.object(deep_agent.sys, "platform", "darwin"):
            result = deep_agent.list_applications.func("chrome")

        self.assertIn("Google Chrome", result)

    def test_open_application_reports_ambiguous_matches(self):
        matches = [
            Path("/Applications/Google Chrome.app"),
            Path("/Applications/Chrome Canary.app"),
        ]
        with mock.patch.object(deep_agent, "_find_matching_applications", return_value=matches), mock.patch.object(
            deep_agent.sys, "platform", "darwin"
        ):
            result = deep_agent.open_application.func("chrome")

        self.assertIn("Multiple applications matched", result)
        self.assertIn("Google Chrome", result)

    def test_open_application_runs_open_command(self):
        completed = subprocess_completed()
        with (
            mock.patch.object(
                deep_agent,
                "_find_matching_applications",
                return_value=[Path("/Applications/Safari.app")],
            ),
            mock.patch.object(deep_agent.sys, "platform", "darwin"),
            mock.patch.object(deep_agent.subprocess, "run", return_value=completed) as run_mock,
        ):
            result = deep_agent.open_application.func("Safari", arguments="--new-window")

        self.assertEqual(result, "Opened Safari with arguments: --new-window")
        args = run_mock.call_args.args[0]
        self.assertEqual(args, ["open", "-a", "/Applications/Safari.app", "--args", "--new-window"])

    def test_run_applescript_blocks_shell_escape(self):
        with mock.patch.object(deep_agent.sys, "platform", "darwin"):
            result = deep_agent.run_applescript.func('do shell script "rm -rf /"')

        self.assertIn("Blocked by safety policy", result)

    def test_run_applescript_executes_through_osascript(self):
        completed = subprocess_completed(stdout="ok\n")
        with (
            mock.patch.object(deep_agent.sys, "platform", "darwin"),
            mock.patch.object(deep_agent.subprocess, "run", return_value=completed) as run_mock,
        ):
            result = deep_agent.run_applescript.func('tell application "Safari" to activate')

        self.assertEqual(result, "ok")
        self.assertEqual(
            run_mock.call_args.args[0],
            ["/usr/bin/osascript", "-e", 'tell application "Safari" to activate'],
        )


def subprocess_completed(
    *, stdout: str = "", stderr: str = "", returncode: int = 0
) -> mock.Mock:
    completed = mock.Mock()
    completed.stdout = stdout
    completed.stderr = stderr
    completed.returncode = returncode
    return completed
