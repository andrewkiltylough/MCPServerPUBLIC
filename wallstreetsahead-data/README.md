# WallStreetsAhead.ai market data for Claude

This plugin lets Claude download the WallStreetsAhead.ai ETF mover reports to a folder on your computer and keep them up to date. Ask Claude to "get the latest market data" and it fetches only what you are missing, then analyses the local files for you.

It works in Claude Code and the Claude desktop app on Windows, macOS and Linux.

> **Not investment advice.** The reports are market data for research and information only. Neither WallStreetsAhead.ai nor Claude's analysis of the reports is financial, investment or trading advice, and nothing here is a recommendation to buy or sell any security. Past moves do not predict future results. Make your own decisions, or consult a licensed adviser.

## What you need

- [Node.js](https://nodejs.org) 18 or later, with `node` on your PATH. Check with `node --version`.
- A WallStreetsAhead.ai API key. See [Getting an API key](#getting-an-api-key).

## Install

From the Claude plugin directory, or from GitHub:

```bash
claude plugin marketplace add andrewkiltylough/MCPServerPUBLIC
```

```bash
claude plugin install wallstreetsahead-data@wallstreetsahead
```

Then type `/plugin` in Claude, choose `wallstreetsahead-data`, and enter your API key. Start a new session and ask: "get the latest market data".

The first fetch downloads the full history, several thousand files, and takes a few minutes. After that each fetch only downloads what is new.

## Getting an API key

Request a key with your name and email address. The key is emailed to you; it is never shown in the response.

macOS or Linux:

```bash
curl -X POST https://api.wallstreetsahead.ai/daybyday-register -H "Content-Type: application/json" -d '{"name":"Your Name","email":"you@example.com"}'
```

Windows PowerShell:

```powershell
Invoke-RestMethod -Method Post -Uri https://api.wallstreetsahead.ai/daybyday-register -ContentType 'application/json' -Body '{"name":"Your Name","email":"you@example.com"}'
```

Each email address can request one key. Keep it private: enter it only through `/plugin`, never in a chat message.

## Settings

All settings are optional except the API key. Set them with `/plugin`.

| Setting | Default | Meaning |
|---|---|---|
| API key | none | Your personal key. Stored in your system's secure credential store. |
| Data folder | `C:\WallStreetsAhead` on Windows, `~/WallStreetsAhead` elsewhere | Where reports are saved. |
| API URL | `https://api.wallstreetsahead.ai/ClaudeCodePlugin` | The WallStreetsAhead.ai API gateway. |

If you used the WallStreetsAhead.ai Windows installer, the plugin also reads the API key and URL it saved in `~/.wallstreetsahead/wallstreetsahead.properties`, so you do not need to enter them again.

## Tools

| Tool | What it does |
|---|---|
| `check_new_data` | Lists which report files are missing or changed locally, without downloading. |
| `fetch_data` | Downloads the missing or changed files. Never deletes anything. |
| `local_status` | Shows what is in your data folder. Does not go online. |
| `list_remote` | Lists one folder of the remote report share. |

`check_new_data` and `fetch_data` accept an optional `etf` (such as `SPY`), a `since` and `until` date range, and `full` to recheck the whole history.

## Example prompts

- "Get the latest SPY data." Claude checks what is missing for SPY, downloads only that, and tells you how many files arrived and for which dates.
- "How current is my market data?" Claude reads your data folder without going online and shows the newest date for each ETF.
- "Fetch today's data, then summarise which XLK holdings moved most in the latest report." Claude brings the folder up to date, then reads the newest XLK report and describes the biggest moves.
- "Check for any gaps in my QQQ history since 2026-09-01 and fill them." Claude rechecks that date range and downloads any files that are missing or changed.

## What it sends, fetches and stores

The plugin runs a small server, [`server/index.mjs`](server/index.mjs), on your computer. It is one readable JavaScript file with no dependencies.

- **It contacts one address:** the API gateway, `https://api.wallstreetsahead.ai/ClaudeCodePlugin` unless you change the API URL. Nothing else.
- **It sends:** your API key, in the `Ocp-Apim-Subscription-Key` header, and the names of the report folders and files it is listing or downloading. It sends no other information about you, your computer or your files.
- **It fetches:** folder listings and report files from the WallStreetsAhead.ai report share, read-only. The gateway reads the share with its own Azure identity, so no storage credential is on your computer.
- **It writes:** downloaded report files inside your data folder, and only there. Remote names that could point outside that folder are refused. It never deletes or changes any other file.
- **It reads:** your data folder, to see what you already have, and the optional settings file above.

Requesting an API key sends the name and email address you type to `https://api.wallstreetsahead.ai/daybyday-register`, which emails the key to that address. The plugin itself never sends your name or email.

The gateway logs which key made each request, when, the file asked for, and the network address it came from, to meter usage and spot abuse. The full [privacy policy](https://wallstreetsahead.ai/privacy.html) says what is collected, why, how long it is kept, and how to have it deleted.

## Troubleshooting

| Message | Fix |
|---|---|
| `node` not found, or the server fails to start | Install Node.js 18 or later, then restart Claude. |
| "No API key found" | Run `/plugin`, choose `wallstreetsahead-data`, enter your key, then start a new session. |
| "The API key was rejected (401)" | The key is wrong or was replaced. Check the email it came in. |
| "not allowed to read this data (403)" | Email support with the address your key was issued to. |
| "usage limit was reached (429)" | Wait and try again later, or email support to have the limit raised. |
| "A key has already been issued to that email address" | Use the key from that email, or email support to have it reissued. |
| "Files to download: 0" | Your data folder is already up to date. |

## Support

Email [support@wallstreetsahead.ai](mailto:support@wallstreetsahead.ai) for key problems, usage limits or anything else. Send it from the address your key was issued to, and never include the key itself. For bugs in the plugin, you can also [open an issue on GitHub](https://github.com/andrewkiltylough/MCPServerPUBLIC/issues).

## License

MIT. See [LICENSE](LICENSE).
