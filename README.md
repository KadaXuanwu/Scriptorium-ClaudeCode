# Scriptorium for Claude Code

The [Scriptorium](https://github.com/KadaXuanwu/Scriptorium) provider for [Claude Code](https://claude.com/claude-code).
Scriptorium's base knows no coding tool. This plugin teaches it one: it starts each run with `claude -p`, reads the
run's log, and knows a Claude plan's models, usage windows, sign-in and refusals.

It runs on a paid Claude plan, never an API key.

## What it needs

- Scriptorium with the provider contract ([docs/PLUGINS.md](https://github.com/KadaXuanwu/Scriptorium/blob/main/docs/PLUGINS.md),
  A provider), with the hooks `GetProbe` and `GetCompact`. An older base finds no probe and no compaction here.
- Claude Code (`claude`) on the PATH, signed in with a paid Claude plan.
- Windows PowerShell 5.1 on Windows, or PowerShell 7.4 or later on macOS and Linux, as the base.

## Use it

In the project's `scriptorium.json`:

```json
"plugins": { "claude": {} }
```

Then run Scriptorium's `setup.ps1` again. For a project that names no provider, setup adds this one by itself while it
is the only provider that Scriptorium lists.

## Accounts

An account is a login folder of Claude Code (`CLAUDE_CONFIG_DIR`). An account with no folder is the command-line login,
`~/.claude`: the plugin takes `CLAUDE_CONFIG_DIR` away for it, also where the PC sets one. The page adds an account in
`~/.claude-<name>` and signs it in. By hand:

```powershell
$env:CLAUDE_CONFIG_DIR = "$HOME\.claude-second"; claude auth login
```

The plugin reads a login from its files and starts no process for it: signed in while `.credentials.json` holds a
refresh token (on macOS the login keychain), the plan and its size from its rate limit tier, the email from
`.claude.json`.

## Models and windows

[models.json](models.json) holds every value that changes with Claude's models and plans, and this page repeats none
of them: the models with their efforts and prices, the model of each complexity, the advisor, the compact size, the
cap of one run, and the usage windows with their default lines. The page's Details tab shows the models, and its
Accounts tab the windows and lines; the owner changes both there.

- **The advisor** (`advisor.model`): a run gets `advisorModel` in its settings file, else
  `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`, so a login's own settings do not count. Each advisor call reads the whole
  session again, uncached.
- **The cap of a run** (`runCap`) is in dollars at the API's price as Claude Code counts them (`--max-budget-usd`).
  It counts the cost of one process, so a resumed session starts at zero again. The largest session in the logs to
  2026-11-19 cost 47.30 dollars.
- **The compact size** (`compactAt`, within `compactRange`): Claude Code takes a window
  (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`) and compacts some tokens before it (`$CompactLead` in [plugin.ps1](plugin.ps1),
  measured with Claude Code 2.1.323), so the plugin gives each run the size plus that lead.
- `price` (dollars for a million tokens, input and output) is read by no script: runs use the plan. It is there for
  whoever weighs a model's cost.
- **The probe's model** (`probeModel`, this plugin's own key): the model of the one-word request that reads an
  account's usage. Take the smallest one.
- **A window's refusal** (`refusal` in a window's entry, this plugin's own key): the words of Claude Code's error when
  that window refuses a request, as plain text. An error that holds them is that window's limit, not the plan's.

The base ignores both keys. The plan's size comes from its rate limit tier: the multiple the tier names (`_20x`),
else 1.

| Window | Name in the settings | What it is |
| ------ | -------------------- | ---------- |
| 5 hours | `five_hour` | the plan's short window; it has the pick-up limits of the ticket sizes |
| Week | `seven_day` | the plan's week; it holds the room kept for your own use |
| A week of some models | `seven_day_overage_included` | a week that only the models its entry names (`models`) count against. Past its lines a new run starts on the entry's `after` model, and no run gets one of its models as advisor |

The names are the ones Claude Code's rate limit events use, and the keys of the stop lines and pick-up limits that an
owner saved. Only a request to one of its models carries the third window; no probe reads it.

Keep `models.json` current: a new model or price, a plan change. Change `updated` with it.

## Token savings

What this plugin saves on Claude Code, beside the base's own savings
([Scriptorium's README](https://github.com/KadaXuanwu/Scriptorium#built-in-token-savings)). A number is a measurement
from run logs, with its date: measure again after a Claude Code update.

| | What | How |
| - | ---- | --- |
| 🚫 | Unused tools blocked | `--disallowedTools` with the tools no run used (`$UnusedTools` in [plugin.ps1](plugin.ps1)): 4,750 tokens less on every turn (631 logs, 2026-11-18). |
| 🧩 | No unused skills | Claude Code's built-in skills and the claude.ai account's are off (`disableBundledSkills`, `syncClaudeAiSkills`): 6,077 tokens less on every turn (2026-11-20). The project's and the plugins' skills stay. |
| 🔌 | Only the plugins' MCP servers | `--mcp-config` with `--strict-mcp-config`: no server of the login or the project loads its tools into a run. |
| 🎛️ | The advisor is set for each run | `advisorModel` in the run's settings file, else `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`: a login's own advisor never runs unasked. |
| 📏 | A bare request for a reading | Ping and the workers' usage reading send one word to the smallest model with no tools, settings, plugins or skills and a one-line system prompt: about 900 tokens (2026-11-20). A refused one costs nothing. |
| 🗜️ | Compact with the run's own arguments | `/compact` on a held session gets the same arguments as the run, so its cache holds and the summary is cheap. |
| 📐 | A compact size for each complexity | `CLAUDE_CODE_AUTO_COMPACT_WINDOW` from the complexity's compact size: a run never carries more context than its owner set. |
| 💰 | A cap for one run | `--max-budget-usd` from `runCap`: a run that goes wrong ends there. |
| 🧱 | One Bash call for independent commands | The playbook has a run chain the calls that do not need each other's result in one call ([PLAYBOOK.md](PLAYBOOK.md)). A trial, as in the base. |
| 🧪 | Trial: no PowerShell tool | `PowerShell` is among the blocked tools: the run's one shell is Bash. |

After a Claude Code update, `tools.ps1 -Logs <a worker's .queue\logs>` prints the tools the runs were given and how
often they called each, to keep the block list right.

## What a run gets

- `--permission-mode auto`, the model and effort, `--add-dir` for the worker's copy in a job in another repo.
- **Tool rules:** each command of the base and of the plugins (`git`, `unity command`) as `Bash(<command>:*)`, the
  rules in Claude Code's own syntax, and every tool of each MCP server a plugin gives. They are a list in the run's
  settings file.

Rules in Claude Code's own syntax go in this plugin's entry in `scriptorium.json`, under `allowedTools`:

```json
"plugins": { "claude": { "allowedTools": ["Bash(npm test:*)", "WebFetch(domain:docs.example.com)"] } }
```

Only Claude Code reads them there. `allowedTools` at the top of `scriptorium.json` and the rules other plugins give are
the older form: every provider gets them, so a project with workers on another tool sends it Claude Code's rules too.
This plugin still reads them.
- **Only the plugins' MCP servers, no unused tool and no unused skill** (Token savings, above).
- **No attribution:** Claude Code's own commit and PR attribution is off.

The two files of a run are in the worker's queue folder: `mcp.json` and `run-settings.json`.

## What each hook does

| Hook | What it does |
| ---- | ------------ |
| `GetLogin` | Reads a login folder's credentials and profile file. Starts nothing |
| `SignIn` | Gives the base `claude auth login` for the folder. The page shows its link and passes it the code |
| `ReadSignIn` | Finds the sign-in link in that command's output, and its last line for a failure |
| `SignOut` | Runs `claude auth logout` for a folder of its own. Never for the command-line login |
| `GetProbe` | Gives the base a request of one word to the smallest model with no tools, settings, plugins or skills and a one-line system prompt (Token savings). It shows the account's usage and whether the account takes requests. A refused one costs nothing. The base runs it, with a time limit |
| `ReadProbe` | Reads the usage, the reply and the refusal from what the probe printed. The limit of a window of some models counts as the plan's limit here |
| `GetCommand` | Writes `mcp.json` and `run-settings.json` and gives the base the `claude -p` command of a run |
| `GetCompact` | Gives the base `claude -p /compact --resume` on a held session with the run's own arguments, so its cache holds. The base runs it, with a time limit |
| `ReadCompact` | Reads the session's size before and after from what the compaction printed. Gives no line for one that failed |
| `ReadUsage` | Reads the windows from a log's last (or first) `rate_limit_event` |
| `ReadRun` | Reads the session, the result (its error, its cost, its refusal by the wording of the error) and the run's numbers from a log |
| `ReadStep` | Says what a log line did: the run's words, or the tool it called |
| `ReadEnd` | Says why a run ended, from the last result of a log |

The refusals it tells apart, each by the CLI's own wording: a model the plan lacks, a refused subscription, a lost
login, the plan's usage limit and the limit of a window of some models. A run that did no work for a cause it does not know counts as one
that did not start, never as its ticket's failure.

## Test it

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File plugin.test.ps1
```

It uses made-up logs and logins and a stand-in for the `claude` command: no Claude Code, no network, no tokens.

## Licence

MIT. See [LICENSE](LICENSE).
