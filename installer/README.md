# Building the Windows installer

This folder builds `wallstreetsahead-plugin-<version>-setup.exe`, a single
file to put on the website. It carries the plugin and a cut-down Java runtime,
so the person installing it needs nothing on their PC beforehand.

## Build it

```powershell
.\installer\build.ps1
```

The script runs `mvn package`, checks the plugin folder is complete, compiles the
Inno Setup script, then prints the path, size and SHA-256 of the setup. The
result lands in `target\installer`.

Pass `-SkipBuild` to recompile the installer without rebuilding the jar, which is
only useful while editing the `.iss` file.

## What you need

| Tool | Why | Install |
|---|---|---|
| JDK 21 or later | Compiles the jar and runs `jlink` for the bundled runtime | See the note on which JDK below |
| Maven 3.9 or later | Builds the project | |
| Inno Setup 6 | Compiles the installer | `winget install --id JRSoftware.InnoSetup --source winget` |

## Which JDK to build releases with

`jlink` copies modules out of whichever JDK Maven is running on, so **the JDK you
build with is the runtime you redistribute**, and its licence travels with your
installer.

Build releases on **Eclipse Temurin 21**. It is GPLv2 with the Classpath
Exception, which permits redistribution inside your own product without
conditions you need to think about. Oracle's own JDK builds are fine to develop
with but their redistribution terms depend on the release and how old it is,
which is not a question worth having hanging over a public download.

```powershell
winget install --id EclipseAdoptium.Temurin.21.JDK --source winget
```

Then build with `JAVA_HOME` pointing at it:

```powershell
$env:JAVA_HOME = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.5.11-hotspot'
.\installer\build.ps1
```

The project targets Java 21 (`maven.compiler.release`), so a Temurin 21 JDK
builds everything without changes.

## Code signing

An unsigned setup downloaded from a website gets a SmartScreen warning
("Windows protected your PC") and a fair number of people will stop there. The
fix is an authenticode signature.

**Signing does not switch the warning off on its own.** SmartScreen trusts a
publisher it has seen before, so reputation accrues with downloads. An **EV**
certificate is the only route that carries trust from the first download; OV and
Trusted Signing earn it over days or weeks. If "no warning, ever, from day one"
is the requirement, EV is the honest answer despite costing several hundred a
year and needing a hardware token.

Reputation attaches to the validated **identity**, not to a particular
certificate. That matters for Trusted Signing, whose certificates are
deliberately short-lived and rotate every few days: the rotation does not reset
anything.

### What is already set up

| | |
|---|---|
| Account | `wsa-trusted-signing` |
| Resource group | `DiscoveryPipeline` |
| Region | North Europe |
| Plan | Basic — about $10/month, 5,000 signatures |
| Endpoint | `https://neu.codesigning.azure.net/` |

### What is left, in order

1. **Identity validation.** Portal only; there is no CLI for it. Azure portal →
   the account → **Identity validation** → **New**. Needs the legal entity name,
   address and website, and takes 1–7 business days. Two things can stop you:
   the organisation normally has to have existed for about three years, and
   availability by country has been expanding from an initial US/Canada launch,
   so confirm Ireland qualifies. Individual validation is the fallback, but it
   puts a personal name on the signature rather than the company's.

2. **Certificate profile**, once validation is approved:

   ```
   az trustedsigning certificate-profile create -g DiscoveryPipeline --account-name wsa-trusted-signing -n wsa-profile --profile-type PublicTrust --identity-validation-id <id-from-step-1>
   ```

3. **Signing tooling.** Neither `signtool.exe` (Windows SDK) nor a working
   `dotnet` is on the build machine. Either install the Windows SDK signing
   components plus the Trusted Signing client, or install the `sign` dotnet
   tool, which speaks to Trusted Signing directly and is less fiddly.

4. **Wire it into Inno Setup.** Register the command under **Tools → Configure
   Sign Tools** as `mysign`, then uncomment in `wallstreetsahead-plugin.iss`:

   ```
   ; SignTool=mysign
   ```

   Add `SignedUninstaller=yes` beside it. The uninstaller is a separate
   executable extracted at install time, and an unsigned one throws its own
   warning months later when somebody removes the program.

5. **Republish.** A signed binary is a different file, so rebuild, copy it to
   the website's `downloads/`, and update the SHA-256 on the download page.

## What the installer does

1. Copies the plugin folder to `%LOCALAPPDATA%\Programs\wallstreetsahead-plugin`.
2. Offers to have an API key issued: the user enters their name, email and the
   shared invite code, and the gateway creates a subscription for them and
   returns the key. Leaving all three blank skips to the next page.
3. Asks for the API URL and key, prefilled from step 2 when a key was issued and
   skipped entirely in that case. Writes them to
   `%USERPROFILE%\.wallstreetsahead\wallstreetsahead.properties`, keeping any other settings
   already in that file. Both fields may be left blank, in which case the finish
   page tells the user to configure the plugin in Claude instead.
4. Creates `C:\WallStreetsAhead` for the downloaded reports.
5. Registers the plugin by running `claude plugin marketplace add` and
   `claude plugin install`. If the Claude CLI cannot be found, the finish page
   shows the two commands to run by hand.

### Key issuance

The `RegisterUrl` define at the top of the `.iss` points at the gateway's
`daybyday-register` API, which is set up in
[azure/README.md](../azure/README.md) section 8. The installer holds no Azure
credentials — only the public gateway address and whatever invite code the person
types — because anything in a published setup can be pulled back out of it.

Every failure path (wrong code, email already registered, rate limited, no
network) leaves the user able to clear the three boxes and type a key by hand, so
a problem at the gateway never blocks the install.

Change the invite code by updating the `daybyday-invite-code` named value in API
Management. It is not compiled into the installer, so no rebuild is needed.

Uninstalling reverses steps 1 and 4, offers to delete the saved API key, and
**leaves `C:\WallStreetsAhead` alone** — those reports are the user's data and can
run to gigabytes.

### Why it never asks for administrator rights

The installer is per user (`PrivilegesRequired=lowest`). This is not politeness:
the Claude CLI is installed under the user's own profile, and both the plugin
registration and the credential store are per user. An elevated installer would
register the plugin for the administrator account rather than the person at the
keyboard, and would not find `claude.exe` at all.

## Publishing checklist

- [ ] Version raised in `pom.xml` **and**
      `wallstreetsahead-plugin\.claude-plugin\plugin.json`
- [ ] Built on Temurin 21
- [ ] Setup signed
- [ ] Installed on a PC with no Java to confirm the bundled runtime works
- [ ] SHA-256 from `build.ps1` published next to the download
- [ ] API keys sent to users separately from the download link
