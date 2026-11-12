# WallStreetsAhead.ai market data for Claude

This adds a tool to Claude that downloads the WallStreetsAhead.ai ETF mover reports to a folder on your PC. Once it is set up, you ask Claude to "get the latest market data" and it fetches whatever you are missing.

Everything runs on your own PC. Nothing is installed on a server, and this folder already contains the built program and its own copy of Java, so you do not need Java, Git or Maven.

## Before you start

- Windows, with Claude Code or the Claude desktop app
- The API URL and your personal API key, which the administrator sends you separately

## 1. Put this folder somewhere permanent

You should already have unzipped it, giving you a folder such as `C:\Tools\wallstreetsahead-plugin`. Claude starts the program from this folder every time, so do not move or delete it afterwards.

It should contain:

```
wallstreetsahead-plugin\
  INSTALL.md                          this file
  .claude-plugin\plugin.json          what the plugin is called, and the API URL and key it asks you for
  .claude-plugin\marketplace.json     lets Claude install this folder
  .mcp.json                           how Claude starts the program
  skills\fetch-market-data\SKILL.md   when to fetch data, and how to read the reports
  lib\wallstreetsahead-mcp.jar                the program itself, about 22 MB
  runtime\                            the copy of Java it runs on, about 46 MB
```

If `lib\wallstreetsahead-mcp.jar` or `runtime\` is missing, the zip was incomplete. Ask the administrator for a new one rather than filling anything in yourself. Do not move anything out of `lib\` or `runtime\`, and do not edit these files.

## 2. Create your data folder

Create an empty folder named `C:\WallStreetsAhead`. The reports are downloaded into it.

This path is fixed. If you need the data somewhere else, ask the administrator.

## 3. Add the plugin

In a terminal, run these two commands. Use your own folder path in the first one.

```bash
claude plugin marketplace add C:\Tools\wallstreetsahead-plugin
```

```bash
claude plugin install wallstreetsahead-data@wallstreetsahead-local
```

## 4. Enter your API URL and key

Open Claude, type `/plugin`, choose `wallstreetsahead-data`, and configure it. Enter the API URL and your API key.

The key is kept in your system's secure credential store, not in a file. Do not paste it into a chat message or save it in a document.

## 5. Try it

1. Start a new Claude session with `C:\WallStreetsAhead` as the folder.
2. When Claude asks whether to trust the `wallstreetsahead-data` server, approve it.
3. Type: `get the latest market data`.
4. Approve the tool when asked. Choose "always allow" to skip the question next time.

The first fetch downloads the full history, about 7,900 files, and takes several minutes. After that, each fetch only downloads what is new.

## Using it

Ask Claude in plain language. For example:

- "Check for new market data"
- "Get the latest data and give me a market update"
- "How current is my data?"
- "Fetch SPY only"
- "Do a full check and repair any gaps"

Files are saved under your data folder in the same layout as the source, for example `C:\WallStreetsAhead\ETF_SPY\10-11-2026\...xlsx`. Nothing is ever deleted from your data folder.

## Updating

The administrator sends you a new zip. Unzip it over the same folder, replacing the files, then run:

```bash
claude plugin marketplace update wallstreetsahead-local
```

Then start a new Claude session. Claude only picks up the new program when a session starts.

## If something goes wrong

| What you see | Likely cause | Fix |
|---|---|---|
| `claude plugin install` says the plugin was not found | The folder was not added as a marketplace | Run the `claude plugin marketplace add` command from step 3 with the path to this folder, then install again. |
| The plugin is installed but the server fails to start | `lib\wallstreetsahead-mcp.jar` or `runtime\` is missing, or the folder was moved after installing | Ask the administrator for a complete zip. If you moved the folder, run the step 3 commands again with the new path. |
| Claude says it has no tool for fetching data | The plugin is not enabled | Type `/plugin` and check `wallstreetsahead-data` is enabled, then start a new session. |
| "No API key found" | The key is not set | Do step 4, then start a new session. |
| "The API key was rejected (401)" | The key is wrong, regenerated, or suspended | Ask the administrator for your current key. |
| "usage limit was reached (429)" | Your key has a quota or rate limit | Wait and retry, or ask the administrator. |
| "Files to download: 0" | Your folder is already up to date | Nothing to do. |

If none of that helps, send the administrator the exact message Claude showed you, and say which step you had reached.
