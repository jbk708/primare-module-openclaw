"""Module-contract tests — guard the release-asset and hook-manifest shape.

These tests catch regressions that would only surface at live-deploy time on
blevit (T12-11): missing hook files, renamed caddy snippet, or accidental
deletion of a release asset the primare-infra generic module role expects.
"""

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
HOOKS_DIR = REPO_ROOT / "hooks"
HOOKS_MANIFEST = REPO_ROOT / "hooks.yml"
CADDY_SNIPPET = REPO_ROOT / "configs" / "caddy" / "module.caddy"


class TestHooksManifest:
    def test_manifest_file_exists(self):
        assert HOOKS_MANIFEST.is_file()

    def test_manifest_is_valid_yaml_with_required_keys(self):
        data = yaml.safe_load(HOOKS_MANIFEST.read_text())
        assert isinstance(data, dict)
        assert "pre_up" in data
        assert "post_up" in data
        assert isinstance(data["pre_up"], list) and len(data["pre_up"]) > 0
        assert isinstance(data["post_up"], list) and len(data["post_up"]) > 0

    def test_every_referenced_hook_path_exists(self):
        data = yaml.safe_load(HOOKS_MANIFEST.read_text())
        for phase in ("pre_up", "post_up"):
            for entry in data.get(phase, []):
                assert isinstance(entry, str), f"{phase} entry must be a path string"
                assert entry.startswith("hooks/"), f"{entry!r} must be under hooks/"
                assert entry.endswith(".yml"), f"{entry!r} must be a .yml file"
                assert (REPO_ROOT / entry).is_file(), (
                    f"{entry} is referenced in hooks.yml but missing on disk"
                )


class TestCaddySnippet:
    def test_snippet_file_exists(self):
        assert CADDY_SNIPPET.is_file()

    def test_snippet_declares_named_block_and_template_vars(self):
        content = CADDY_SNIPPET.read_text()
        assert "(module_openclaw)" in content, (
            "snippet must be named (module_openclaw) for the generic Caddy loader"
        )
        assert "{{ path_prefix }}" in content, "snippet must template path_prefix"
        assert "{{ module_name }}" in content, "snippet must template module_name"
        assert "{{ module_port }}" in content, "snippet must template module_port"


class TestReleaseAssetPresence:
    """Regression guard — release workflow uploads these files as assets.

    If a contributor deletes any of these, the release asset set breaks and
    the primare-infra generic module role's fetch step 404s at deploy time
    on blevit. CI catching it here is much cheaper than live-cluster failure.
    """

    def test_caddy_snippet_present(self):
        assert CADDY_SNIPPET.is_file()

    def test_hooks_manifest_present(self):
        assert HOOKS_MANIFEST.is_file()

    def test_all_hooks_directory_files_present(self):
        expected = {
            "set-defaults.yml",
            "assert-secrets.yml",
            "persist-gateway-token.yml",
            "create-dirs.yml",
            "apply-config.yml",
            "create-default-agent.yml",
            "configure-discord.yml",
            "bind-discord-agent.yml",
            "install-log-metrics.yml",
            "smoke-test.yml",
            "openclaw-log-metrics.sh",
            "openclaw-log-metrics.service.j2",
            "openclaw-log-metrics.timer.j2",
        }
        actual = {p.name for p in HOOKS_DIR.iterdir() if p.is_file()}
        missing = expected - actual
        assert not missing, (
            f"hooks/ is missing expected release-asset files: {sorted(missing)}"
        )
