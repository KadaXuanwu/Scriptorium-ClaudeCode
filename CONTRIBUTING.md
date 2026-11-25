# Contributing

This plugin follows the rules of the base. Read
[Scriptorium's CONTRIBUTING.md](https://github.com/KadaXuanwu/Scriptorium/blob/main/.github/CONTRIBUTING.md) first.

What this repo adds:

1. Keep to the plugin contract, version 1, and its part on a provider
   ([docs/PLUGINS.md](https://github.com/KadaXuanwu/Scriptorium/blob/main/docs/PLUGINS.md)).
2. `plugin.ps1` only defines functions when it loads. It starts nothing and changes nothing. It calls no function of
   the base.
3. A change to a hook has a test in `plugin.test.ps1` and a line in `README.md` in the same pull request.
4. A wording of a refusal that the plugin learns gets its real result line as a test, cut to the fields the plugin
   reads. Put no real log, email or credential in this repo.
5. A change to how a run works on Claude Code goes into `PLAYBOOK.md`.
6. Run `powershell -NoProfile -ExecutionPolicy Bypass -File plugin.test.ps1` before you open the pull request, and
   `pwsh -NoProfile -File plugin.test.ps1` on macOS or Linux.
