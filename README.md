# WallStreetsAhead.ai data for Claude

This adds a tool to Claude that downloads the WallStreetsAhead.ai ETF mover reports from Azure to a folder on your PC. Once it is set up, you ask Claude to "get the latest market data" and it fetches whatever you are missing.

It runs on your own PC. Nothing is installed on a server.

## Install it (the easy way)

Download `wallstreetsahead-plugin-<version>-setup.exe` and run it. It installs the plugin for your user only, so there is no administrator prompt, creates the data folder, and registers the plugin with Claude. Nothing else needs to be installed first — it carries its own copy of Java.

For the API key, enter your name, your email address and the invite code the administrator gave you, and one is issued to you during the install. If you already have a key, leave those blank and type the key on the next page instead.

When it finishes, start a new Claude session in `C:\WallStreetsAhead` and ask for the latest market data. That is the whole install; the rest of this section is only for the zip.

See [installer/README.md](installer/README.md) for how the setup is built and signed.

## Install it from a zip

The administrator gives you one zip file, for example `wallstreetsahead-plugin-0.2.0.zip`. It contains the built program and its own copy of Java, so you do not need Java, Git, Maven or this repository.

You need:

- Windows with Claude Code or the Claude desktop app
- The API URL and your personal API key, from the administrator

### 1. Unzip it

Unzip it somewhere permanent, so that you end up with a folder such as `C:\Tools\wallstreetsahead-plugin`. Claude starts the program from this folder every time, so do not move or delete it afterwards.

Inside that folder you should see exactly these files:

```
wallstreetsahead-plugin\
  INSTALL.md                          these steps, for the person installing it
  .claude-plugin\plugin.json          what the plugin is called, and the API URL and key it asks you for
  .claude-plugin\marketplace.json     lets Claude install this folder
  .mcp.json                           how Claude starts the program
  skills\fetch-market-data\SKILL.md   when to fetch data, and how to read the reports
  lib\wallstreetsahead-mcp.jar                the program itself, about 22 MB
  runtime\                            the copy of Java it runs on, about 46 MB
```

If any of them are missing, the install will fail. Ask the administrator for a complete zip rather than filling anything in yourself. Do not move anything out of `lib\` or `runtime\`, and do not edit these files.

### 2. Create your data folder

Create an empty folder named `C:\WallStreetsAhead`. The reports are downloaded into it.

### 3. Add the plugin

In a terminal, run these two commands. Use your own unzip path in the first one.

```bash
claude plugin marketplace add C:\Tools\wallstreetsahead-plugin
```

```bash
claude plugin install wallstreetsahead-data@wallstreetsahead-local
```

### 4. Enter your API URL and key

Open Claude, type `/plugin`, choose `wallstreetsahead-data`, and configure it. Enter the API URL and your API key. The key is kept in your system's secure credential store, not in a file.

### 5. Try it

Start a new Claude session with `C:\WallStreetsAhead` as the folder and type `get the latest market data`. Approve the `wallstreetsahead-data` server and the tool when asked; choose "always allow" to skip the question next time.

The first fetch downloads the full history, about 7,900 files, and takes several minutes. After that, each fetch only downloads new files. See [Using it](#using-it) for what you can ask.

### Updating

The administrator gives you a new zip. Unzip it over the same folder, replacing the files, then run:

```bash
claude plugin marketplace update wallstreetsahead-local
```

Then start a new Claude session. Claude only picks up the new program when a session starts.

## Packaging a release (administrator)

The folder `wallstreetsahead-plugin` in this repository **is** the plugin. The five small files in it are committed, including `INSTALL.md`, the user's instructions. `mvn package` writes the jar into `wallstreetsahead-plugin\lib` and jlinks a cut-down Java runtime into `wallstreetsahead-plugin\runtime`, so after a build the folder is complete and ready to hand out. There is nothing to stage and nothing to assemble by hand.

```bash
mvn package
```

There are two ways to ship it.

### As an installer, for the website

```powershell
.\installer\build.ps1
```

That produces one setup `.exe` in `target\installer`, which is what you put on the download page. [installer/README.md](installer/README.md) covers what you need, which JDK to build releases with, code signing, and a publishing checklist.

### As a zip, for sending directly

Check it before you send it:

```bash
claude plugin validate wallstreetsahead-plugin
```

Then zip the folder. In PowerShell, from the repository folder:

```powershell
Compress-Archive -Path wallstreetsahead-plugin -DestinationPath wallstreetsahead-plugin-0.2.0.zip -Force
```

That zip is the whole deliverable, and the only thing you send: it carries `INSTALL.md`, so there is no separate set of instructions to keep in sync, and this README stays in the repository for you. Send the API key separately, not in the same message as the zip.

The jar must stay at `lib\wallstreetsahead-mcp.jar` and the runtime at `runtime\`, because those are the paths `.mcp.json` uses.

`lib\` and `runtime\` are in `.gitignore`, because 69 MB of build output does not belong in Git. That also means a marketplace added straight from the Git repository has neither, and will not start — always send the installer or the zip.

Raise `version` in both `wallstreetsahead-plugin\.claude-plugin\plugin.json` and `pom.xml` for each release, and name the zip after it, so users can tell which one they have.

The data folder is fixed at `C:\WallStreetsAhead` by `.mcp.json`, so every user gets that path. Anyone who needs a different folder has to edit `.mcp.json` in their unzipped plugin folder.

Everything below is the manual route: build the jar yourself and wire it up by hand. Use it if you are working on the code.

## What you need (building from source)

- Windows with the Claude desktop app (Code tab) or Claude Code
- Java 21 or later
- Maven 3.9 or later
- Git, and access to this repository
- An API key and the API URL, from the administrator

To check Java and Maven, run each of these in a terminal. Both should print a version number.

```bash
java -version
```

```bash
mvn -v
```

## Setup from source

### 1. Get the code

```bash
git clone https://github.com/andrewkiltylough/MCPServerPUBLIC.git C:\PreMindWorkSpace\MCPServer
```

You can use a different folder. If you do, use that path wherever `C:\PreMindWorkSpace\MCPServer` appears below.

### 2. Build it

```bash
cd C:\PreMindWorkSpace\MCPServer
```

```bash
mvn package
```

This creates `target\wallstreetsahead-mcp.jar`, copies it to `wallstreetsahead-plugin\lib\wallstreetsahead-mcp.jar`, and builds the bundled Java runtime into `wallstreetsahead-plugin\runtime`. The first build downloads libraries and takes a few minutes; the jlink step adds about half a minute to every build after that, and `-Dplugin.runtime.skip=true` skips it when you do not need it.

If you only want to use the tool on this machine, you can stop here and install the plugin folder you just built, instead of doing steps 3 to 6:

```bash
claude plugin marketplace add C:\PreMindWorkSpace\MCPServer\wallstreetsahead-plugin
```

```bash
claude plugin install wallstreetsahead-data@wallstreetsahead-local
```

Then follow [Enter your API URL and key](#4-enter-your-api-url-and-key) onwards. The steps below are the hand-wired alternative, which gives you control over the jar path and the data folder.

### 3. Create your data folder

Create an empty folder for the reports. These steps use `C:\WallStreetsAhead`.

### 4. Tell Claude about the tool

In `C:\WallStreetsAhead`, create a file named `.mcp.json` with this content:

```json
{
  "mcpServers": {
    "wallstreetsahead-data": {
      "command": "java",
      "args": ["-jar", "C:/PreMindWorkSpace/MCPServer/target/wallstreetsahead-mcp.jar"],
      "env": {
        "WALLSTREETSAHEAD_LOCAL_ROOT": "C:\\WallStreetsAhead"
      }
    }
  }
}
```

Do not put your API key in this file. Put it in the settings file described under [API key](#api-key).

Two details matter:

- The jar path uses forward slashes.
- The data folder path uses double backslashes. A single backslash makes the file invalid and Claude will not load it.

### 5. Add the skill

Copy the folder `wallstreetsahead-plugin\skills\fetch-market-data` from this repository to `C:\WallStreetsAhead\.claude\skills\fetch-market-data`. The result should be:

```
C:\WallStreetsAhead\.claude\skills\fetch-market-data\SKILL.md
```

The skill tells Claude when to fetch data and how to read the reports.

### 6. Start Claude

1. Open the Claude desktop app and start a new session with `C:\WallStreetsAhead` as the folder.
2. When Claude asks whether to trust the `wallstreetsahead-data` server, approve it.
3. Type: `get the latest market data`.
4. Approve the tool when asked. Choose "always allow" to skip the question next time.

The first fetch downloads the full history, about 7,900 files, and takes several minutes. After that, each fetch only downloads new files.

## Using it

Ask Claude in plain language. For example:

- "Check for new market data"
- "Get the latest data and give me a market update"
- "How current is my data?"
- "Fetch SPY only"
- "Do a full check and repair any gaps"

Files are saved under your data folder in the same layout as Azure, for example `C:\WallStreetsAhead\ETF_SPY\10-11-2026\...xlsx`. Nothing is ever deleted from your data folder.

## API key

The tool needs a personal API key. Data is fetched through the team's Azure API Management gateway, which checks the key and records usage against it. Ask the administrator for your key and the API URL, or let the Windows installer issue you one from your name, email and an invite code. Administrators: see [azure/README.md](azure/README.md) for how the gateway is set up, how to issue keys by hand, and how to turn on self-service issuance.

**If you installed this as a Claude plugin**, Claude asks for the API URL and key when you enable it. The key is kept in your system's secure credential store. To change them later, open `/plugin`, choose `wallstreetsahead-data`, and configure it.

**If you set it up with `.mcp.json` as above**, create `C:\Users\<you>\.wallstreetsahead\wallstreetsahead.properties`:

```
apiUrl=https://<gateway>.azure-api.net/daybyday
apiKey=<your API key>
```

Never commit this file or paste the key into a chat. You can also set the environment variables `WALLSTREETSAHEAD_API_URL` and `WALLSTREETSAHEAD_API_KEY` instead; they override the file.

## Updating a source build

When the code changes:

```bash
cd C:\PreMindWorkSpace\MCPServer
```

```bash
git pull
```

```bash
mvn package
```

Then start a new Claude session. Claude only picks up the new jar when a session starts.

## If something goes wrong

| What you see | Likely cause | Fix |
|---|---|---|
| `claude plugin install` says the plugin was not found | The folder was not added as a marketplace | Run `claude plugin marketplace add` with the path to your unzipped `wallstreetsahead-plugin` folder, then install again. |
| The plugin is installed but the server fails to start | `lib\wallstreetsahead-mcp.jar` is missing from the folder | Ask the administrator for a complete zip. If you built it yourself, run `mvn package`. |
| Claude says it has no tool for fetching data | `.mcp.json` was not loaded | Check the file is in the folder you opened, the backslashes are doubled, and you approved the server. Start a new session. |
| Claude lists the server as failed | The jar path is wrong or the jar was not built | Run `mvn package` and check the path in `.mcp.json`. |
| "No API key found" | The key is not set | Set it as described under [API key](#api-key), then start a new session. |
| "The API key was rejected (401)" | The key is wrong, regenerated, or suspended | Ask the administrator for your current key. |
| "usage limit was reached (429)" | Your key has a quota or rate limit | Wait and retry, or ask the administrator. |
| "Files to download: 0" | Your folder is already up to date | Nothing to do. |
| `java` is not recognised | Java is not installed or not on the PATH | Install Java 21 and reopen the terminal. |

## For developers

The project is a standard Maven project and imports into Eclipse with **File → Import → Maven → Existing Maven Projects**.

The repository holds three things: the Java server under `src`, the plugin folder `wallstreetsahead-plugin` that is handed to users, and `installer`, which wraps that folder in a setup `.exe`. Edit the plugin manifest, `.mcp.json` and the skill inside the plugin folder; `mvn package` fills in its `lib` and `runtime`, and `mvn clean` empties both again.

The plugin runs on the bundled runtime, not on whatever Java the user has: `.mcp.json` names `${CLAUDE_PLUGIN_ROOT}/runtime/bin/java.exe`. The module list for that runtime is the `plugin.runtime.modules` property in `pom.xml`. If you add a dependency that needs a module the list does not have, the server fails to start with a `NoClassDefFoundError`; re-run `jdeps` against `target\wallstreetsahead-mcp.jar` and add what it reports.

- `Main` is the server Claude launches. It never talks to the storage account directly: `GatewayPolicy` sends every Azure SDK request to the API Management gateway with the API key attached. Run on its own it waits silently for input, which is normal.
- `DevRunner` runs the Azure check without Claude. With no arguments it only reports what is missing. Add the program argument `fetch` to download, an ETF code such as `SPY` to limit it, or `full` to check every date folder.
- Do not print to standard output in `Main` or `ShareSync`. Standard output carries the protocol Claude uses, and stray output breaks the connection. Use standard error.

The tools Claude can call:

| Tool | What it does |
|---|---|
| `local_status` | Shows what is in the local data folder. Does not contact Azure. |
| `check_new_data` | Reports which files are missing or changed, without downloading. |
| `fetch_data` | Downloads missing or changed files. |
| `list_remote` | Lists one folder in the Azure share. |
