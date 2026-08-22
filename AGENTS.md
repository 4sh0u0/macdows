# AGENTS.md

Working rules for this repository — for AI coding agents and human contributors alike.

## Security red lines

No tracked file may ever contain:

- Real Windows host IP addresses or hostnames
- RDP credentials
- Private-network addresses
- Personal data

Such values belong only in untracked local files (`.env*`, `*.local.md` — see
`.gitignore`). CI's Tier 1 workflow (`.github/workflows/tier1.yml`) enforces this on
every push: a red-line regex scan against `.github/scan-patterns.txt`, plus `gitleaks`.
RAIL protocol capture samples must be sanitized before being committed.

## Conventions

- Commit style: `<type>: <summary>` (`feat` / `fix` / `docs` / `chore` / `refactor` /
  `test` / `build`)
- Commit messages and code comments: English
- Code comments cite design decision records as `adr/NNNN §n`. Those records are
  maintained privately by the project owner and their numbering is stable; the
  comments' technical content stands on its own — treat the citations as provenance
  markers, and keep them intact when editing.

## Verification discipline

The build and the `MacdowsCore` package tests must pass before any change is claimed
complete:

```sh
swift test --package-path Packages/MacdowsCore
xcodebuild -project App/Macdows.xcodeproj -scheme Macdows build
```

`Tools/window-smoke` (end-to-end RAIL verification against a real Windows host) is
opt-in — it requires a live host and credentials supplied via environment variables or
an untracked local file, never checked in. It is not part of standard verification and
should not block a change on its own absence.
