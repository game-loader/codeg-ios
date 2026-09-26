# Changelog

All notable changes to Codeg for iOS are recorded here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add changes under `## [Unreleased]` as you land them. When you cut a release,
`scripts/release.sh` moves that section under a new version heading and reuses
the text as the git tag message and the GitHub Release notes.

## [Unreleased]

### Added

- **New agent types** — DeepSeek Harness, Qoder, and Google Antigravity, plus
  registry (`custom:…`) agents. Unknown agent types used to be read as Claude
  Code (and shown and reconnected as such); they now keep their own identity.
- Retry progress (`turn_retrying`, retry-class session failures) shows as a
  transient banner that clears once the turn moves on.
- The approval card shows how many more permission requests are queued.
- Secret questions (`is_secret`) take a masked answer field.
- On/off agent config options appear in the options sheet.
- Folder aliases show as `alias [ name ]`, as on the web.

### Changed

- Apple signing now uses an ignored local configuration instead of a committed
  development team identifier.
- An `error` event no longer ends the turn: like the web client, only
  `turn_complete` or a dropped connection does, and errors are routed by code
  (turn failure, action notice, or session problem).
- Expert Skills are read from `experts_list` + `experts_list_all_install_statuses`
  (the per-agent `experts_list_for_agent` endpoint was removed server-side).

### Fixed

- Typed session failures (`session_failure`) are shown instead of ignored, so a
  failed turn explains why.
- A failed turn's error stays on screen after the transcript reconciles.
- Sub-agent prose (`parent_tool_use_id`) streams into its tool card instead of
  being mixed into the main reply.
- A session that can't be restored (`session_load_failed`) ends the turn with a
  reason instead of hanging.
- Saving proxy, terminal, or GitHub account settings no longer wipes fields the
  app doesn't edit (`no_proxy`, `colorize_command_output`, account `provider`).
- A finished tool call recorded without a result no longer spins forever when
  the transcript records its status.
- Sending on a connection the server already dropped now reconnects and retries
  instead of failing with "connection not found".

## [1.0.1] - 2026-07-07

### Added

- **New agent types** — CodeBuddy, Kimi Code, and Pi.
- One-command release automation: `scripts/release.sh` bumps the version, files
  the release notes, tags, pushes, and creates a GitHub Release (with an
  optional `--archive` App Store Connect upload leg).
- This `CHANGELOG.md` as the home for version notes.

### Changed

- The app version is now single-sourced from `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` in `project.yml`.

### Fixed

- Streaming no longer rebuilds the entire transcript on every token, keeping
  long sessions smooth.
- The pending approval card is restored after a mid-turn stream reconnect.
- `Info.plist` no longer hardcodes `CFBundleShortVersionString`, which had
  silently overridden `MARKETING_VERSION` so version bumps didn't take effect.

## [1.0.0] - 2026-06-07

### Added

- Initial Codeg for iOS release.
