# Security Policy

## Reporting a Vulnerability

Obsidian Vault Git Watcher runs `git` in the folders you add (stage, commit, push), so
security reports are taken seriously. Please **do not** open a public issue for security
problems.

Instead, use GitHub's private vulnerability reporting
(**Security → Report a vulnerability** on this repository).

You'll get an acknowledgement within a few days. Once a fix is available it will be released
and the report disclosed, with credit unless you prefer otherwise.

## Scope

The app runs entirely on-device. Its only network traffic is the `git push` you configure,
to your own remote. Relevant areas: how `config.json` values reach `git` (remote and branch
names are validated so they can't be read as options), what the commit action stages, and
the LaunchAgent it installs for launch at login.
