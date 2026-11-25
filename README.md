# Scriptorium for Claude Code

The [Scriptorium](https://github.com/KadaXuanwu/Scriptorium) provider for [Claude Code](https://claude.com/claude-code).
Scriptorium's base knows no coding tool. This plugin teaches it one: it starts each run with `claude -p`, reads the
run's log, and knows a Claude plan's models, usage windows, sign-in and refusals.

It runs on a Claude Pro or Max plan, never an API key.

## What it needs

- Scriptorium with the provider contract ([docs/PLUGINS.md](https://github.com/KadaXuanwu/Scriptorium/blob/main/docs/PLUGINS.md),
  A provider).
- Claude Code (`claude`) on the PATH, signed in with a Claude Pro or Max plan.
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
refresh token (on macOS the login keychain), the plan from its rate limit tier (Pro counts as 1, Max 5x as 5, Max 20x
as 20), the email from `.claude.json`.

## Models and windows

[models.json](models.json) holds what the base asks a provider: the models with their efforts, the candidates of each
complexity, the advisor, the compact size, the cap of one run and the usage windows.

| Complexity | Model |
| ---------- | ----- |
| `low` | Opus 5.5 at medium effort |
| `medium` | Opus 5.5 at high effort, with the advisor |
| `high` | Opus 5.5 at xhigh effort, with the advisor |
| `design` | Fable 5.2 at high effort |

- **The advisor** is Fable 5.2. A run gets `advisorModel` in its settings file, else
  `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`, so a login's own settings do not count. Each advisor call reads the whole
  session again, uncached.
- **The cap of a run** (`runCap`, 60) is in dollars at the API's price as Claude Code counts them (`--max-budget-usd`).
  It counts the cost of one process, so a resumed session starts at zero again. The largest session in the logs to
  2026-11-19 cost 47.30 dollars.
- **The compact size** (`compactAt`, 250000; from 67000 to 967000): Claude Code takes a window
  (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, from 100000 to 1000000) and compacts 33000 tokens before it (measured with Claude
  Code 2.1.323), so the plugin gives each run the size plus 33000.
- `price` (dollars for a million tokens, input and output) is read by no script: runs use the plan. It is there for
  whoever weighs a model's cost. A Fable ticket costs about 2.5 times an Opus one of its size.

| Window | Name in the settings | Default lines |
| ------ | -------------------- | ------------- |
| 5 hours | `five_hour` | workers stop at 98 %; no new L ticket from 50 %, M from 75 %, S from 90 % |
| Week | `seven_day` | workers stop at 100 %; it holds the room kept for your own use |
| Fable week | `seven_day_overage_included` | Fable alone: no new Fable run from 90 % (`design`), no Fable advisor from 98 %; a job goes on with Opus 5.5 at xhigh |

The names are the ones Claude Code's rate limit events use, and the keys of the stop lines and pick-up limits that an
owner saved. Only a Fable request carries the Fable week; no probe reads it.

Keep `models.json` current: a new model or price, a plan change. Change `updated` with it.

## What a run gets

- `--permission-mode auto`, the model and effort, `--add-dir` for the worker's copy in a job in another repo.
- **Tool rules:** each command of the base and of the plugins (`git`, `unity command`) as `Bash(<command>:*)`, the
  rules in Claude Code's own syntax from `allowedTools` in `scriptorium.json` and from the plugins, and every tool of
  each MCP server a plugin gives. They are a list in the run's settings file.
- **Only the plugins' MCP servers** (`--mcp-config` with `--strict-mcp-config`).
- **No unused tools:** `--disallowedTools` with the tools no run used in 631 logs, 4,750 tokens less on every turn
  (`$UnusedTools` in [plugin.ps1](plugin.ps1)). `PowerShell` is among them, as a trial: the run's one shell is Bash.
  After a Claude Code update, `tools.ps1 -Logs <a worker's .queue\logs>` prints the tools the runs were given and how
  often they called each.
- **No unused skills:** Claude Code's built-in skills and the claude.ai account's are off (`disableBundledSkills`,
  `syncClaudeAiSkills`), 6,077 tokens less on every turn. The project's and the plugins' skills stay.
- **No attribution:** Claude Code's own commit and PR attribution is off.

The two files of a run are in the worker's queue folder: `mcp.json` and `run-settings.json`.

## What each hook does

| Hook | What it does |
| ---- | ------------ |
| `GetLogin` | Reads a login folder's credentials and profile file. Starts nothing |
| `SignIn` | Gives the base `claude auth login` for the folder. The page shows its link and passes it the code |
| `ReadSignIn` | Finds the sign-in link in that command's output, and its last line for a failure |
| `SignOut` | Runs `claude auth logout` for a folder of its own. Never for the command-line login |
| `Probe` | Sends one word to Haiku with no tools, settings, plugins or skills and a one-line system prompt, about 900 tokens. It shows the account's usage and whether the account takes requests. A refused one costs nothing |
| `GetCommand` | Writes `mcp.json` and `run-settings.json` and gives the base the `claude -p` command of a run |
| `Compact` | Runs `claude -p /compact --resume` on a held session with the run's own arguments, so its cache holds. Ends it after 10 minutes |
| `ReadUsage` | Reads the windows from a log's last (or first) `rate_limit_event` |
| `ReadRun` | Reads the session, the result (its error, its cost, its refusal by the wording of the error) and the run's numbers from a log |
| `ReadStep` | Says what a log line did: the run's words, or the tool it called |
| `ReadEnd` | Says why a run ended, from the last result of a log |

The refusals it tells apart, each by the CLI's own wording: a model the plan lacks, a refused subscription, a lost
login, the plan's usage limit and the Fable limit. A run that did no work for a cause it does not know counts as one
that did not start, never as its ticket's failure.

## Test it

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File plugin.test.ps1
```

It uses made-up logs and logins and a stand-in for the `claude` command: no Claude Code, no network, no tokens.

## Licence

MIT. See [LICENSE](LICENSE).
