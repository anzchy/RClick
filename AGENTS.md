# AGENTS.md

The project rules for every agent (Codex, Kimi, Claude) are in [CLAUDE.md](CLAUDE.md). Read it first: architecture,
build and test commands, the Swift 6.2 / SwiftUI / macOS 15 constitution, localization (two catalogs), and the
`## Agent skills` section.

- Skills: `.agents/skills/` (`.claude/skills` is a symlink to it).
- Issues and PRs: `anzchy/RClick` only. Run `gh repo set-default anzchy/RClick` in every worktree; never write to
  upstream `wflixu/RClick`.
- Before handing off a change, run the `rclick-verify` skill (gate ladder: `scripts/gates.sh`).
- Codex role rules: `.codex/rules/rclick.rules` plus the per-worktree overlay from
  `scripts/codex-rules/install-role.py`.
