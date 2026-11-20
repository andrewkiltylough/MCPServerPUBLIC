# Using WallStreetsAhead.ai data with your own agent

The `wallstreetsahead-data` plugin is packaged for Claude, but nothing in it depends on Claude. It contains:

- an MCP server, [`server/index.mjs`](server/index.mjs): one JavaScript file with no dependencies that speaks the Model Context Protocol over stdio
- a skill, [`skills/fetch-market-data/SKILL.md`](skills/fetch-market-data/SKILL.md): plain-language instructions telling the model when to fetch and how to read the reports

You can connect it to another agent in either of two ways:

| | Option A: run the MCP server | Option B: call the HTTP gateway directly |
|---|---|---|
| Use it when | Your agent or framework supports MCP over stdio | Your agent has no MCP support, runs on a server without Node.js, or you want your own sync logic |
| You need | Node.js 18+ and an API key | An API key and any HTTP client |
| You get | 4 ready-made tools that mirror reports to a local folder | Raw folder listings (XML) and file downloads |

Both options need an API key.

---

## 1. Get an API key

Each email address can request one key. The key is emailed to you and never appears in the response.

```bash
curl -X POST https://api.wallstreetsahead.ai/daybyday-register \
  -H "Content-Type: application/json" \
  -d '{"name":"Your Name","email":"you@example.com"}'
```

```powershell
Invoke-RestMethod -Method Post -Uri https://api.wallstreetsahead.ai/daybyday-register -ContentType 'application/json' -Body '{"name":"Your Name","email":"you@example.com"}'
```

Treat the key like a password. Keep it in an environment variable or the settings file described below. Don't put it in a prompt, in committed config, or anywhere the model can read it back.

---

## 2. Option A: run the MCP server

### Get the server

```bash
git clone https://github.com/andrewkiltylough/MCPServerPUBLIC.git
```

The server is `MCPServerPUBLIC/wallstreetsahead-data/server/index.mjs`. It needs no `npm install`. You can copy that one file anywhere.

### Configure it

The server reads each setting from an environment variable first, then from a settings file, then falls back to a default.

| Environment variable | Settings file key | Default | Meaning |
|---|---|---|---|
| `WALLSTREETSAHEAD_API_KEY` | `apiKey` | none (required) | Your API key |
| `WALLSTREETSAHEAD_API_URL` | `apiUrl` | `https://api.wallstreetsahead.ai/ClaudeCodePlugin` | The gateway. It must be `https://`. |
| `WALLSTREETSAHEAD_LOCAL_ROOT` | `localRoot` | `C:\WallStreetsAhead` on Windows, `~/WallStreetsAhead` elsewhere | Where reports are saved |
| `WALLSTREETSAHEAD_SETTINGS_FILE` | n/a | `~/.wallstreetsahead/wallstreetsahead.properties` | Location of the settings file |

The path `/ClaudeCodePlugin` is only the gateway's name, and it serves every client. Leave `WALLSTREETSAHEAD_SHARE_NAME` and `WALLSTREETSAHEAD_REMOTE_ROOT` unset: the gateway refuses any other path with `403`.

We recommend putting the key in the settings file rather than in your agent's config:

```properties
# ~/.wallstreetsahead/wallstreetsahead.properties
apiKey=<your API key>
localRoot=/data/WallStreetsAhead
```

Some MCP clients don't pass their own environment to the servers they start. The settings file works in those clients too.

### Register it with your agent

Every client below starts the server as `node /path/to/server/index.mjs` over stdio. Only the config format differs. Use an absolute path to `index.mjs`.

**Clients that use the common `mcpServers` JSON** (Cursor, Windsurf, Cline, Continue, Goose and many others):

```json
{
  "mcpServers": {
    "wallstreetsahead-data": {
      "command": "node",
      "args": ["/abs/path/to/MCPServerPUBLIC/wallstreetsahead-data/server/index.mjs"],
      "env": {
        "WALLSTREETSAHEAD_LOCAL_ROOT": "/data/WallStreetsAhead"
      }
    }
  }
}
```

**VS Code / GitHub Copilot** (`.vscode/mcp.json`):

```json
{
  "servers": {
    "wallstreetsahead-data": {
      "type": "stdio",
      "command": "node",
      "args": ["/abs/path/to/server/index.mjs"]
    }
  }
}
```

**OpenAI Codex CLI** (`~/.codex/config.toml`):

```toml
[mcp_servers.wallstreetsahead-data]
command = "node"
args = ["/abs/path/to/server/index.mjs"]
```

**OpenAI Agents SDK (Python):**

```python
from agents import Agent, Runner
from agents.mcp import MCPServerStdio

async with MCPServerStdio(
    params={"command": "node", "args": ["/abs/path/to/server/index.mjs"]},
    client_session_timeout_seconds=600,   # a fetch can take minutes
) as wsa:
    agent = Agent(name="Markets", instructions=WSA_INSTRUCTIONS, mcp_servers=[wsa])
    result = await Runner.run(agent, "Get the latest market data and summarise SPY")
```

**LangChain / LangGraph** (`langchain-mcp-adapters`):

```python
from langchain_mcp_adapters.client import MultiServerMCPClient

client = MultiServerMCPClient({
    "wallstreetsahead-data": {
        "command": "node",
        "args": ["/abs/path/to/server/index.mjs"],
        "transport": "stdio",
    }
})
tools = await client.get_tools()
```

Each framework's config format changes between versions. If a field name here doesn't match yours, check its MCP documentation. The command and arguments stay the same.

**If your agent only connects to MCP over HTTP** (for example, a hosted agent), the server doesn't offer HTTP itself. Run it behind a stdio-to-HTTP bridge such as `mcp-proxy` or `supergateway` on a machine you control. The reports are still written to that machine's disk, so your agent also needs read access to that folder.

### Check it works without an agent

The server speaks newline-delimited JSON-RPC on stdin and stdout, so you can test it by hand:

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"local_status","arguments":{}}}' \
 | node server/index.mjs
```

It supports protocol versions `2024-11-05`, `2025-03-26`, `2025-06-18` and `2025-11-25`. It handles requests one at a time, so two fetches never write the same files at once.

### The tools

| Tool | Arguments | What it does |
|---|---|---|
| `local_status` | none | Shows the local folder, whether a key is set, and the newest date folder for each ETF. Makes no network calls. |
| `check_new_data` | `etf`, `since`, `until`, `full` | Lists missing or changed files, grouped by date folder. Downloads nothing. |
| `fetch_data` | `etf`, `since`, `until`, `full` | Downloads missing or changed files. Never deletes anything. |
| `list_remote` | `path` | Lists one remote folder, for example `ETF_SPY` or `ETF_SPY/10-09-2026`. |

- `etf`: one ticker, such as `SPY` or `XLK`. Leave it out for all ETFs.
- `since`, `until`: a date folder range, as `YYYY-MM-DD`.
- `full`: `true` re-checks the whole history. This is slow, so use it only to repair gaps.

With no arguments, a check starts 3 days before the newest local date folder for each ETF, because later runs add files to recent folders.

Every tool returns a single `text` content block. When a tool fails, the result has `isError: true` and text starting with `Error:`, and the connection stays open.

### Timeouts and the first sync

The first `fetch_data` downloads the full history: about 8,000 files, which takes several minutes. Many MCP clients cancel a tool call after about 60 seconds. Either:

- raise your client's tool-call timeout, as `client_session_timeout_seconds` does above, or
- do the first sync before the agent ever runs, for example with your own script that calls the tool once, or one ETF at a time (`{"etf":"SPY"}`).

After the first sync, each fetch only downloads new files and finishes quickly.

### Give the model the instructions

Claude loads `SKILL.md` automatically. Other agents won't, so add something like this to your system prompt:

```text
You have WallStreetsAhead.ai market data tools.
- Before analysing market data, call check_new_data. If files are missing, call fetch_data with the same
  arguments, then report how many files were downloaded, for which date folders, and any failures.
- Use local_status to answer "how current is my data?". Use list_remote only to investigate when a fetch finds nothing.
- Use full=true only when asked to repair gaps or rebuild the data.
- If a tool says the API key is missing, rejected, not allowed, or over its limit, or that the gateway
  could not be reached, report the message and stop. Do not retry. Never ask the user to paste an API key.
- Reports are under <data folder>/ETF_<TICKER>/<MM-DD-YYYY>/*.xlsx.
  Folder names do not sort as text, so parse them as dates.
  A folder's date is not the trading date: check the price timestamps inside the files.
  The newest folder is often partial, and the newest few folders overlap.
```

Your agent then reads the `.xlsx` files from the data folder with its own file or spreadsheet tools. The MCP server only syncs files. It doesn't parse them.

---

## 3. Option B: call the HTTP gateway directly

The gateway is a read-only proxy in front of an Azure Files share. It accepts the Azure Files REST API, `GET` only, under one root folder.

**Base URL** (all paths go under this):

```
https://api.wallstreetsahead.ai/ClaudeCodePlugin/premind-stock/SignalMoves/DayByDayRunner
```

**Headers on every request:**

```
Ocp-Apim-Subscription-Key: <your API key>
x-ms-version: 2024-11-04
```

**List a folder.** Add `?restype=directory&comp=list`:

```bash
curl -H "Ocp-Apim-Subscription-Key: $WSA_KEY" -H "x-ms-version: 2024-11-04" \
  "https://api.wallstreetsahead.ai/ClaudeCodePlugin/premind-stock/SignalMoves/DayByDayRunner/ETF_SPY?restype=directory&comp=list"
```

The response is Azure Files XML:

```xml
<EnumerationResults ...>
  <Entries>
    <Directory><Name>10-09-2026</Name></Directory>
    <File><Name>report.xlsx</Name><Properties><Content-Length>48213</Content-Length></Properties></File>
  </Entries>
  <NextMarker>...</NextMarker>
</EnumerationResults>
```

If `<NextMarker>` isn't empty, request the folder again with `&marker=<value>` added, and repeat until it is empty.

The body starts with a UTF-8 byte-order mark. Parse the raw bytes, or strip the leading `﻿` before parsing the response as a string. Otherwise, parsers such as Python's `ElementTree.fromstring(str)` reject it.

**Download a file.** `GET` its path with no query string:

```bash
curl -H "Ocp-Apim-Subscription-Key: $WSA_KEY" -H "x-ms-version: 2024-11-04" -o report.xlsx \
  "https://api.wallstreetsahead.ai/ClaudeCodePlugin/premind-stock/SignalMoves/DayByDayRunner/ETF_SPY/10-09-2026/<file name>.xlsx"
```

URL-encode each path segment separately, and don't encode the `/` between segments.

**Folder layout:**

```
<root>/
  ETF_SPY/            one folder per ETF: SPY, QQQ, DIA, IWM, XLK, XLF, ... (ETE_XLE is a historical misspelling of ETF_XLE)
    10-09-2026/       date folders named MM-DD-YYYY
      *.xlsx          the mover reports
```

**Responses:**

| Status | Meaning | What to do |
|---|---|---|
| 200 | OK | |
| 401 | Key missing, wrong or regenerated | Fix the key. Don't retry. |
| 403 | Path is outside the root, or the key isn't allowed | Check the path. Don't retry. |
| 429 | Usage limit reached | Back off, or contact us |
| 5xx / network error | Temporary | Retry with backoff. The plugin tries 3 times. |

**Recommended sync logic**, the same as the plugin uses:

1. List the root to get the ETF folders.
2. For each ETF, list its date folders. Skip folders older than 3 days before the newest one you already have.
3. List each remaining date folder. Download a file when you don't have it locally, or when your local size differs from `Content-Length`.
4. Write to a temporary file and rename it when complete. Check the byte count against `Content-Length`.
5. Run at most about 8 requests at once.
6. Never use a remote name as a path without checking it. Reject names that contain `/`, `\`, `:` or `..`.

To expose this to your agent without MCP, wrap these as function-calling tools, such as `list_folder(path)` and `download(path)`, or better, a single `sync(etf?, since?)` that runs the steps above. Return short text summaries rather than raw XML, so they don't use up the model's context.

---

## Support

- Key problems or limits: contact WallStreetsAhead.ai with the email address your key was issued to.
- Bugs in the server: open an issue at https://github.com/andrewkiltylough/MCPServerPUBLIC.
