# Playbook: Claude Code

What a run on Claude Code adds to Scriptorium's `PLAYBOOK.md`. A name in brackets is a part of that playbook.

**The rules file.** The project's rules file is `CLAUDE.md`; in a project that has none, `AGENTS.md`. Claude Code
loads it into your context: do not read it again (step 2). In a job in another repository (`PLAYBOOK-repo.md`), this
repo's rules file is in an added folder, so it is not in your context: read it in step 2.

**One shell.** You have one shell, Bash (One shell). The calls that do not need each other's result go out as one Bash
call that chains them with `;` (Turns).

**Compaction.** Claude Code compacts your context when it grows large: the checkpoint's commit and `progress.json` are
what you find again after it (Checkpoints).

**No AI attribution anywhere:** no `Co-Authored-By`, no "Generated with Claude Code" line, in commits, PR descriptions
or comments.
