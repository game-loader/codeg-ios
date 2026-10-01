# Changelog

All notable changes to Codeg for iOS are recorded here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add changes under `## [Unreleased]` as you land them. When you cut a release,
`scripts/release.sh` moves that section under a new version heading and reuses
the text as the git tag message and the GitHub Release notes.

## [Unreleased]

### Added

- Common file attachments from the iOS Files picker, including Excel, Word,
  PDF, presentations, text/code, archives, audio and video. Files are copied
  and uploaded from disk with progress, cancellation, and explicit retry, then
  sent as server file references. Large files do not become inline/base64 chat
  payloads; the selected server's upload limit applies.
- Messages composed during a running task can be queued without stopping it.
  Compatible Codex sessions with live feedback enabled receive queued messages
  after a tool finishes; ordinary end-of-turn delivery remains the fallback.
  The queue preserves images, shows delivery receipts, and keeps failed drafts
  available for retry. Agent-delegation mentions use ordinary prompt delivery.
- GitHub Actions builds sideloading IPAs (ad-hoc signed, no certificate) and
  attaches them with SHA-256 checksums to releases, with tag and manual
  triggers.
- **New agent types** — DeepSeek Harness, Qoder, and Google Antigravity, plus
  registry (`custom:…`) agents. Unknown agent types used to be read as Claude
  Code (and shown and reconnected as such); they now keep their own identity.
- Retry progress (`turn_retrying`, retry-class session failures) shows as a
  transient banner that clears once the turn moves on.
- The approval card shows how many more permission requests are queued.
- Secret questions (`is_secret`) take a masked answer field.
- On/off agent config options appear in the options sheet.
- Folder aliases show as `alias [ name ]`, as on the web.
- User turns list what the server flattened into them (attachments,
  `@`-mentions, pages from the built-in browser, machine and paper context) as
  chips under the message instead of raw links and context dumps. A web chip
  opens the site; a machine or paper chip shows the context that was sent.
- Tapping a file link in a reply opens the file preview; a session reference
  opens that conversation.
- A CI workflow builds every pushed branch for device.
- **Machines** (Folders → Tools on iPhone, the sidebar on iPad): the server's
  Tailscale peers and manually added SSH hosts. A machine opens to a live SSH
  probe of its hardware and load, with a Tailscale login link when discovery or
  a probe needs one; manual machines can be added, edited and removed. The
  probe result can be inserted into a message, and the composer's **+** →
  **Machine…** picks a machine without leaving the conversation.
- **Academic** (next to Machines): the server's paired Zotero library, by
  collection and with search. Papers can be added by arXiv id, URL or DOI, and
  a paper's preparation (PDF, analysis, code repository) is followed live,
  including choosing an arXiv match or a repository. **Start Asking** opens a
  conversation bound to the paper — in its cloned repository when code was
  found, as a chat otherwise — and a bound conversation shows a paper bar that
  opens the paper. Zotero pairing and the research agent are set from the
  library.

### Changed

- Markdown renders closer to the web client: inline code is a monospaced pill,
  file and `codeg://` references are colored tokens with an icon, web links are
  underlined, lists nest (with task checkboxes and CommonMark numbering), quotes
  can hold lists and code, tables size columns to their content, and headings
  get section spacing. User messages render Markdown too, keeping indentation.
- Code blocks use primary text on a panel that is visible in dark mode, and only
  show a language label when the fence names one.
- Tool titles are no longer parsed as Markdown (`__init__.py` stayed bold), and
  file paths in tool cards and diffs show an icon for their type.
- Server errors show their detail (such as the SSH error or a Tailscale login
  link) under the message.
- Apple signing now uses an ignored local configuration instead of a committed
  development team identifier.
- The bundle identifier can be overridden the same way
  (`CODEG_BUNDLE_IDENTIFIER`), so the app can be signed with a personal (free)
  Apple ID team.
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
