---
name: fetch-market-data
description: Get the latest WallStreetsAhead.ai ETF mover reports from Azure before analysing them. Use when the user asks to fetch, refresh, sync, update or download the market data, asks for "today's data", or asks for a market update and the local data may be stale.
---

# Fetch WallStreetsAhead.ai market data

The reports live in an Azure file share and are mirrored to a local folder (default `C:\WallStreetsAhead`). The `wallstreetsahead-data` MCP server does the mirroring. Analysis always runs on the local files.

## Steps

1. Call `check_new_data` with no arguments. It reports how many files are missing locally, grouped by date folder, without downloading.
2. If files are missing, call `fetch_data` with the same arguments. It downloads only missing or changed files and never deletes anything local.
3. Tell the user how many files were downloaded, which date folders they belong to, and whether any failed.
4. Then continue with whatever the user asked for, reading the local files.

## Arguments

Both tools take the same optional arguments:

- `etf`: one ETF such as `SPY` or `XLK`. Omit for all 28.
- `since`, `until`: date folder range as `YYYY-MM-DD`.
- `full`: `true` checks every date folder back to December 2025. It is slow, so use it only when the user asks to repair gaps or rebuild the local copy.

With no arguments the check starts three days before the newest local date folder for each ETF, because later runs add files to recent folders.

## Other tools

- `local_status`: what is on disk now, without contacting Azure. Use it to answer "how current is my data?".
- `list_remote`: list one folder in the share. Use it to investigate when a fetch finds nothing.

## If a tool returns an error

- "No API key found" or "No API URL found": the setting is missing. Tell the user where to set it (the message says) and that Claude must be restarted afterwards. Never ask the user to paste the API key into the chat.
- "API key was rejected", "not allowed" or "usage limit was reached": report the message as given and stop; do not retry.
- Other authentication or "share not found" errors: report the message as given and stop; do not retry.

## Reading the data afterwards

- Folder names are `MM-DD-YYYY` and do not sort as text; parse them as dates.
- The folder date is not the trading date. Check the price timestamps inside the files.
- The newest folder is often partial and the newest few folders repeat each other.
