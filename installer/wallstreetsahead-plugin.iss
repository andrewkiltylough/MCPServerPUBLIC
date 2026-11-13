; Inno Setup script for the WallStreetsAhead.ai plugin for Claude.
;
; Builds a single per-user setup .exe for the website. It installs no system
; files and never asks for administrator rights, which matters for more than
; politeness: the Claude CLI lives under the user's own profile, and the plugin
; registration and credential store are per user. An elevated installer would
; register the plugin for the administrator account instead of the person
; sitting at the machine.
;
; Compile with installer\build.ps1, which builds the plugin folder first.
; Compiling this file on its own produces a setup that is missing the jar and
; the bundled runtime.

#define AppName "WallStreetsAhead.ai plugin for Claude Code"
#define AppShortName "wallstreetsahead-plugin"
#define AppPublisher "WallStreetsAhead.ai"
#define MarketplaceName "wallstreetsahead-local"
#define PluginId "wallstreetsahead-data"
#define DataFolder "C:\WallStreetsAhead"
#define PluginSource "..\wallstreetsahead-plugin"

; Self-service key issuance. The gateway creates the API Management subscription
; and returns the key; see azure\apim-register-policy.xml. Nothing secret lives
; here, only the public gateway address and whatever code the user types.
; The gateway address the plugin talks to, and the open endpoint that issues keys.
#define ApiUrl "https://api.wallstreetsahead.ai/ClaudeCodePlugin"
#define RegisterUrl "https://api.wallstreetsahead.ai/daybyday-register"

; The one line the finish page tells the user to paste into Claude to prove the
; plugin is live. It names the tool outright rather than describing the task, so
; the check does not depend on Claude inferring which tool to reach for, and it
; calls the cheapest tool that still proves the API key works. Keep it under 62
; characters or it wraps on the finish page.
#define TestPrompt "Use the wallstreetsahead-data tool to list the remote reports"

; Version comes from build.ps1 (/DAppVersion=...), which reads it from pom.xml.
#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

[Setup]
; Never change AppId: it is how Windows recognises an upgrade of this product.
; This one is new as of the rename, so a machine still carrying the old
; pre-rename install keeps it as a separate entry rather than being upgraded in
; place. Uninstall that one by hand if you find it.
AppId={{B3EA108A-97F0-4B9D-891B-F17924E9D9A0}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\{#AppShortName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
; Per-user install, so no UAC prompt and no elevation.
; Keep a log, so a failed registration leaves something to read afterwards.
; It lands in %TEMP%Setup Log <date> #NNN.txt.
SetupLogging=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\target\installer
OutputBaseFilename={#AppShortName}-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}
LicenseFile=
; Code signing: see installer\README.md. Without it, Windows SmartScreen warns
; everyone who downloads the setup. Supply a signtool command named "mysign" in
; your Inno Setup configuration and uncomment:
; SignTool=mysign

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; The whole plugin folder, exactly as Claude expects to find it: the manifests,
; .mcp.json, the skill, lib\wallstreetsahead-mcp.jar and the bundled runtime.
Source: "{#PluginSource}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Dirs]
; The data folder survives uninstall. It holds the downloaded reports, which can
; be many gigabytes and are the user's, not ours.
Name: "{#DataFolder}"; Flags: uninsneveruninstall

[Tasks]
; Ticked by default, but shown rather than done quietly: this widens what Claude
; is allowed to read, and that should be the user's visible choice.
Name: "claudedir"; Description: "Let Claude Code read {#DataFolder} from any session (recommended)"; GroupDescription: "Claude Code setup:"

[Messages]
; The welcome page is the one place a person can still turn back, so it says
; outright what this is and what it needs. People arriving from the website have
; downloaded a .exe and may reasonably expect an application; what they are
; getting is a plugin that does nothing without Claude Code.
WelcomeLabel2=This installs the WallStreetsAhead.ai plugin for Claude Code, Anthropic's coding agent. Claude Code must already be installed: the plugin gives it a market-data tool, it is not an application you open, and it does not work in the Claude chat at claude.ai, in the Claude mobile apps, or with any other AI assistant.%n%nThis is an early beta. Coverage has gaps, reports will change, and some of what it produces will be wrong, so check what it tells you rather than rely on it. You are among the first people to use it at all, and that support is worth a great deal - thank you. Tell us what breaks: support@wallstreetsahead.ai.%n%nNothing is installed outside your own user account and no administrator rights are needed.

; The finish page text depends on whether the API key was entered, so it is set
; from code below.

[Code]
var
  RegisterPage: TInputQueryWizardPage;
  ApiPage: TInputQueryWizardPage;
  ClaudeExe: String;
  RegistrationNote: String;
  DirNote: String;
  KeyIssued: Boolean;
  { True once the test prompt is on the clipboard, so the finish page only
    promises a paste that will actually produce something. }
  ClipboardReady: Boolean;
  { Set when the person can fix the problem by editing the two boxes. Anything
    else must let the install continue: a key service problem is not a reason
    to refuse to install the software. }
  StayToRetry: Boolean;

const
  SettingsDirName = '.wallstreetsahead';
  SettingsFileName = 'wallstreetsahead.properties';

function SettingsFile(): String;
begin
  Result := AddBackslash(GetEnv('USERPROFILE')) + SettingsDirName + '\' + SettingsFileName;
end;

{ Reads one key out of an existing settings file, so the wizard can prefill. }
function ReadSetting(const Key: String): String;
var
  Lines: TArrayOfString;
  I: Integer;
  Line: String;
begin
  Result := '';
  if not FileExists(SettingsFile()) then
    Exit;
  if not LoadStringsFromFile(SettingsFile(), Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    Line := Trim(Lines[I]);
    if (Length(Line) > 0) and (Line[1] <> '#') and (Line[1] <> '!') then
      if Pos(LowerCase(Key) + '=', LowerCase(Line)) = 1 then
      begin
        Result := Trim(Copy(Line, Length(Key) + 2, Length(Line)));
        Exit;
      end;
  end;
end;

{
  Rewrites apiUrl and apiKey and leaves every other line alone. The same file can
  hold shareName, remoteRoot and localRoot, and a user who set those by hand
  should not lose them to an upgrade.
}
procedure WriteSettings(const ApiUrl, ApiKey: String);
var
  Existing, Output: TArrayOfString;
  I, N: Integer;
  Line, Lower: String;
begin
  N := 0;
  SetArrayLength(Output, 0);
  if FileExists(SettingsFile()) and LoadStringsFromFile(SettingsFile(), Existing) then
  begin
    for I := 0 to GetArrayLength(Existing) - 1 do
    begin
      Line := Existing[I];
      Lower := LowerCase(Trim(Line));
      if (Pos('apiurl=', Lower) = 1) or (Pos('apikey=', Lower) = 1) then
        Continue;
      SetArrayLength(Output, N + 1);
      Output[N] := Line;
      N := N + 1;
    end;
  end;
  SetArrayLength(Output, N + 2);
  Output[N] := 'apiUrl=' + ApiUrl;
  Output[N + 1] := 'apiKey=' + ApiKey;
  ForceDirectories(AddBackslash(GetEnv('USERPROFILE')) + SettingsDirName);
  SaveStringsToFile(SettingsFile(), Output, False);
end;

{
  Finds the Claude CLI. It is installed per user, so it is usually not on the
  PATH of a fresh process; the known locations are checked first and `where` is
  the fallback.
}
{
  The Claude desktop app ships its own copy of the CLI and does not put it on
  the PATH or in any of the per-user locations above. It lives under
  %APPDATA%\Claude\claude-code\<version>\<hash>\claude.exe, so both levels have
  to be walked. Someone who installed the desktop app and never the standalone
  CLI has a perfectly working Claude and nothing the checks above can see,
  which left the plugin unregistered with no way to tell why.

  Highest version wins, because an upgraded app leaves the older folders in
  place and the newest is the one actually in use.
}
function FindDesktopClaude(): String;
var
  Root, Candidate: String;
  VerRec, HashRec: TFindRec;
  Best, Current: Int64;
begin
  Result := '';
  Best := 0;
  Root := AddBackslash(GetEnv('APPDATA')) + 'Claude\claude-code\';
  if not DirExists(Root) then
    Exit;
  if not FindFirst(Root + '*', VerRec) then
    Exit;
  try
    repeat
      if (VerRec.Name <> '.') and (VerRec.Name <> '..')
         and ((VerRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0)
         and StrToVersion(VerRec.Name, Current)
         and ((Best = 0) or (ComparePackedVersion(Current, Best) > 0)) then
      begin
        if FindFirst(Root + VerRec.Name + '\*', HashRec) then
        try
          repeat
            if (HashRec.Name <> '.') and (HashRec.Name <> '..')
               and ((HashRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) then
            begin
              Candidate := Root + VerRec.Name + '\' + HashRec.Name + '\claude.exe';
              if FileExists(Candidate) then
              begin
                Result := Candidate;
                Best := Current;
                Break;
              end;
            end;
          until not FindNext(HashRec);
        finally
          FindClose(HashRec);
        end;
      end;
    until not FindNext(VerRec);
  finally
    FindClose(VerRec);
  end;
end;

function FindClaude(): String;
var
  Candidates: TArrayOfString;
  I, Code: Integer;
  TempFile: String;
  Lines: TArrayOfString;
begin
  Result := '';
  SetArrayLength(Candidates, 3);
  Candidates[0] := AddBackslash(GetEnv('USERPROFILE')) + '.local\bin\claude.exe';
  Candidates[1] := AddBackslash(GetEnv('APPDATA')) + 'npm\claude.cmd';
  Candidates[2] := AddBackslash(GetEnv('LOCALAPPDATA')) + 'Programs\claude\claude.exe';
  for I := 0 to GetArrayLength(Candidates) - 1 do
    if FileExists(Candidates[I]) then
    begin
      Result := Candidates[I];
      Log('Claude CLI found at a known path: ' + Result);
      Exit;
    end;

  Result := FindDesktopClaude();
  if Result <> '' then
  begin
    Log('Claude CLI found in the desktop app: ' + Result);
    Exit;
  end;

  TempFile := ExpandConstant('{tmp}\claude-path.txt');
  if Exec(ExpandConstant('{cmd}'), '/c where claude > "' + TempFile + '" 2>nul',
          '', SW_HIDE, ewWaitUntilTerminated, Code) then
    if (Code = 0) and LoadStringsFromFile(TempFile, Lines) and (GetArrayLength(Lines) > 0) then
      if FileExists(Trim(Lines[0])) then
        Result := Trim(Lines[0]);

  if Result <> '' then
    Log('Claude CLI found on the PATH: ' + Result)
  else
    Log('Claude CLI not found: checked the known paths, the desktop app folder and the PATH.');
end;

{ Runs one claude subcommand. Returns True when it exits 0. }
function RunClaude(const Args: String): Boolean;
var
  Code: Integer;
begin
  Result := Exec(ExpandConstant('{cmd}'), '/c ""' + ClaudeExe + '" ' + Args + '"',
                 '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
  { Registration failing used to leave only a line on the finish page, which is
    gone the moment the window closes. }
  Log('claude ' + Args + ' -> exit ' + IntToStr(Code));
end;

function JsonEscape(const S: String): String;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C = '"' then
      Result := Result + '\"'
    else if C = '\' then
      Result := Result + '\\'
    else if (C = #13) or (C = #10) or (C = #9) then
      Result := Result + ' '
    else
      Result := Result + C;
  end;
end;

{
  Synchronous POST. WinHttp rather than Inno's own DownloadTemporaryFile, which
  only does GET and cannot carry a request body.
}
function PostJson(const Url, Body: String; var Status: Integer; var ResponseText: String): Boolean;
var
  Http: Variant;
begin
  Result := False;
  Status := 0;
  ResponseText := '';
  try
    Http := CreateOleObject('WinHttp.WinHttpRequest.5.1');
    Http.SetTimeouts(15000, 15000, 15000, 30000);
    Http.Open('POST', Url, False);
    Http.SetRequestHeader('Content-Type', 'application/json');
    Http.Send(Body);
    Status := Http.Status;
    ResponseText := Http.ResponseText;
    Result := True;
  except
    { No network, DNS failure, TLS failure: Status stays 0. }
    Result := False;
  end;
end;

{ Reads one key=value line out of the gateway's properties-format reply. }
function ValueFromProperties(const Text, Key: String): String;
var
  Start, Stop: Integer;
  Rest: String;
begin
  Result := '';
  Start := Pos(Key + '=', Text);
  if Start = 0 then
    Exit;
  Rest := Copy(Text, Start + Length(Key) + 1, Length(Text));
  Stop := 1;
  while (Stop <= Length(Rest)) and (Rest[Stop] <> #13) and (Rest[Stop] <> #10) do
    Stop := Stop + 1;
  Result := Trim(Copy(Rest, 1, Stop - 1));
end;

{
  Asks the gateway to issue a key and email it to the address given, then fills
  in the API URL ready for the person to paste the key beside it. The key is
  never returned over HTTP: delivering it to the mailbox is what proves the
  address belongs to them. Every failure path leaves the user able to clear
  both boxes and type a key by hand, so a registration problem never blocks
  the install.
}
function RequestKey(): Boolean;
var
  PersonName, Email, Body, Response, Url, Sent: String;
  Status: Integer;
begin
  Result := False;
  StayToRetry := False;
  PersonName := Trim(RegisterPage.Values[0]);
  Email := Trim(RegisterPage.Values[1]);

  Body := '{"name":"' + JsonEscape(PersonName) + '","email":"' + JsonEscape(Email) + '"}';

  if not PostJson('{#RegisterUrl}', Body, Status, Response) then
  begin
    MsgBox('Could not reach the key service.' + #13#10#13#10 +
           'The install will carry on. Add your API URL and key on the next page' + #13#10 +
           'if you have them, or in Claude Code afterwards with /plugin.', mbError, MB_OK);
    Exit;
  end;

  if Status = 200 then
  begin
    { The key is emailed, never returned here. Only the API URL comes back. }
    Url := ValueFromProperties(Response, 'apiUrl');
    Sent := ValueFromProperties(Response, 'sent');
    if Pos('https://', LowerCase(Url)) <> 1 then
    begin
      MsgBox('The key service replied with something unexpected.' + #13#10 +
             'Ask the administrator for a key and enter it on the next page.', mbError, MB_OK);
      Exit;
    end;
    if Sent = '' then
      Sent := Email;
    ApiPage.Values[0] := Url;
    MsgBox('Your API key has been emailed to ' + Sent + '.' + #13#10#13#10 +
           'It can take a minute to arrive and may land in your junk folder.' + #13#10#13#10 +
           'Paste it on the next page when it comes. If you would rather not wait,' + #13#10 +
           'leave the key box empty and finish the install: you can add the key in' + #13#10 +
           'Claude Code at any time with /plugin.', mbInformation, MB_OK);
    Result := True;
    Exit;
  end;

  if Status = 409 then
    MsgBox('A key has already been emailed to ' + Email + '.' + #13#10#13#10 +
           'Use the key from that email and paste it on the next page, or ask the' + #13#10 +
           'administrator to reissue it. The install will carry on either way.', mbError, MB_OK)
  else if Status = 400 then
  begin
    { The only failure the person can fix here, so it is the only one that waits. }
    StayToRetry := True;
    MsgBox('Check the name and email address, then try again.', mbError, MB_OK);
  end
  else
    MsgBox('The key service returned an error (HTTP ' + IntToStr(Status) + ').' + #13#10#13#10 +
           'The install will carry on. Ask the administrator for a key and add it' + #13#10 +
           'on the next page, or in Claude Code afterwards with /plugin.', mbError, MB_OK);
end;

procedure InitializeWizard();
begin
  RegisterPage := CreateInputQueryPage(wpSelectDir,
    'Get your API key',
    'Have a key emailed to you.',
    'Enter your name and email address, and your key will be sent to that address.' + #13#10 +
    'Leave both blank if you already have an API key.');
  RegisterPage.Add('Name:', False);
  RegisterPage.Add('Email:', False);

  ApiPage := CreateInputQueryPage(RegisterPage.ID,
    'WallStreetsAhead.ai API access',
    'Where the market data comes from.',
    'Enter the API URL and the personal API key the administrator sent you.' + #13#10 +
    'You can leave both blank and set them in Claude Code later with /plugin.');
  ApiPage.Add('API URL:', False);
  ApiPage.Add('API key:', True);
  ApiPage.Values[0] := ReadSetting('apiUrl');
  ApiPage.Values[1] := ReadSetting('apiKey');
  { A setup from before the gateway moved has the retired address saved, and
    that path now returns 404. Offering it back would have the person confirm
    a dead URL. The key itself still works against the new address. }
  if Pos('azure-api.net/daybyday', LowerCase(ApiPage.Values[0])) > 0 then
    if Pos('daybyday-register', LowerCase(ApiPage.Values[0])) = 0 then
      ApiPage.Values[0] := '{#ApiUrl}';
  if ApiPage.Values[0] = '' then
    ApiPage.Values[0] := 'https://';
end;

{
  The API page is always shown. The key arrives by email rather than in the
  reply, so even a successful registration leaves the person something to paste.
}
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Url, Key: String;
  Filled: Integer;
begin
  Result := True;

  if CurPageID = RegisterPage.ID then
  begin
    Filled := 0;
    if Trim(RegisterPage.Values[0]) <> '' then Filled := Filled + 1;
    if Trim(RegisterPage.Values[1]) <> '' then Filled := Filled + 1;

    { Both blank means "I already have a key", which the next page collects. }
    if Filled = 0 then
    begin
      KeyIssued := False;
      Exit;
    end;
    if Filled < 2 then
    begin
      MsgBox('Fill in both boxes to have a key emailed to you, or clear them both' + #13#10 +
             'to enter a key you already have.', mbError, MB_OK);
      Result := False;
      Exit;
    end;

    KeyIssued := RequestKey();
    { Only a correctable mistake holds the wizard here. Everything else moves
      on, so a problem at the key service never stops the software installing. }
    Result := KeyIssued or (not StayToRetry);
    Exit;
  end;

  if CurPageID <> ApiPage.ID then
    Exit;

  Url := Trim(ApiPage.Values[0]);
  Key := Trim(ApiPage.Values[1]);

  { Both blank means "I will do it in Claude later", which is allowed. }
  if ((Url = '') or (Url = 'https://')) and (Key = '') then
    Exit;

  if Pos('https://', LowerCase(Url)) <> 1 then
  begin
    MsgBox('The API URL must start with https:// so your API key is not sent in clear text.',
           mbError, MB_OK);
    Result := False;
    Exit;
  end;
  if Key = '' then
  begin
    MsgBox('Enter your API key, or clear the API URL as well and set both in Claude Code later.',
           mbError, MB_OK);
    Result := False;
  end;
end;

{
  Adds the data folder to Claude's own settings, so any session can read the
  downloaded reports rather than only one started in that folder.

  The merge is done by PowerShell instead of by editing the JSON as text.
  settings.json belongs to Claude and may already hold the person's own entries;
  a clumsy string edit would break their setup rather than ours. The original is
  copied to settings.json.bak first, and an entry that is already there is left
  alone.
}
function AllowClaudeToReadDataFolder(): Boolean;
var
  Script: TArrayOfString;
  ScriptFile: String;
  Code: Integer;
begin
  Result := False;
  ScriptFile := ExpandConstant('{tmp}\wsa-claude-settings.ps1');

  SetArrayLength(Script, 20);
  Script[0]  := '$ErrorActionPreference = "Stop"';
  Script[1]  := '$dir = $args[0]';
  Script[2]  := '$path = Join-Path $env:USERPROFILE ".claude\settings.json"';
  Script[3]  := '$folder = Split-Path $path';
  Script[4]  := 'if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }';
  Script[5]  := '$obj = $null';
  Script[6]  := 'if (Test-Path $path) {';
  Script[7]  := '  Copy-Item $path ($path + ".bak") -Force';
  Script[8]  := '  $raw = Get-Content $path -Raw';
  Script[9]  := '  if (-not [string]::IsNullOrWhiteSpace($raw)) { $obj = $raw | ConvertFrom-Json }';
  Script[10] := '}';
  Script[11] := 'if ($obj -eq $null) { $obj = New-Object PSObject }';
  Script[12] := 'if (-not $obj.PSObject.Properties["permissions"]) { Add-Member -InputObject $obj -MemberType NoteProperty -Name permissions -Value (New-Object PSObject) }';
  Script[13] := 'if (-not $obj.permissions.PSObject.Properties["additionalDirectories"]) { Add-Member -InputObject $obj.permissions -MemberType NoteProperty -Name additionalDirectories -Value @() }';
  { Built with a loop, not a pipeline: a one-element array comes back from a
    PowerShell pipeline as a bare string, and "+" would then join the paths into
    one instead of adding to the list. }
  Script[14] := '$dirs = @()';
  Script[15] := 'foreach ($d in @($obj.permissions.additionalDirectories)) { if ($d) { $dirs += $d } }';
  Script[16] := 'if ($dirs -notcontains $dir) { $dirs += $dir }';
  Script[17] := '$obj.permissions.additionalDirectories = @($dirs)';
  Script[18] := '$json = $obj | ConvertTo-Json -Depth 20';
  Script[19] := '[System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))';

  if not SaveStringsToFile(ScriptFile, Script, False) then
    Exit;
  if not Exec('powershell.exe',
              '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptFile + '" "{#DataFolder}"',
              '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Exit;
  Result := (Code = 0);
end;

{ Inno has no clipboard function, so this borrows PowerShell's. -STA is not
  optional: the clipboard is an apartment-threaded API and Set-Clipboard fails
  without it. Run during post-install rather than when the finish page opens,
  so the one-second cost of starting PowerShell is hidden by work the user is
  already waiting on. A single quote in the text would break out of the
  -Command argument, so it is doubled on the way in. }
function CopyToClipboard(Text: String): Boolean;
var
  Code: Integer;
begin
  StringChangeEx(Text, '''', '''''', True);
  Result := Exec('powershell.exe',
                 '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass' +
                 ' -Command "Set-Clipboard -Value ''' + Text + '''"',
                 '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Url, Key: String;
begin
  if CurStep <> ssPostInstall then
    Exit;

  ClipboardReady := CopyToClipboard('{#TestPrompt}');

  if WizardIsTaskSelected('claudedir') then
    if not AllowClaudeToReadDataFolder() then
      DirNote :=
        'Claude Code was not given access to {#DataFolder}, so you will' + #13#10 +
        'need to start sessions in that folder, or add it yourself with' + #13#10 +
        '/add-dir.';

  Url := Trim(ApiPage.Values[0]);
  Key := Trim(ApiPage.Values[1]);
  if (Key <> '') and (Pos('https://', LowerCase(Url)) = 1) then
    WriteSettings(Url, Key);

  { Register the plugin with Claude. }
  ClaudeExe := FindClaude();
  if ClaudeExe = '' then
  begin
    RegistrationNote :=
      'Claude Code was not found on this PC, so the plugin could not be' + #13#10 +
      'registered. This is a plugin for Claude Code and does nothing' + #13#10 +
      'without it. Install Claude Code, then run these two commands:' + #13#10#13#10 +
      '  claude plugin marketplace add "' + ExpandConstant('{app}') + '"' + #13#10 +
      '  claude plugin install {#PluginId}@{#MarketplaceName}';
    Exit;
  end;

  { An existing marketplace entry makes `add` fail, which is fine on an upgrade. }
  if not RunClaude('plugin marketplace add "' + ExpandConstant('{app}') + '"') then
    RunClaude('plugin marketplace update {#MarketplaceName}');

  if RunClaude('plugin install {#PluginId}@{#MarketplaceName}') then
    RegistrationNote := ''
  { Already installed, which is the normal case on an upgrade: point it at the
    new files instead of reporting a failure the user cannot act on. }
  else if RunClaude('plugin update {#PluginId}') then
    RegistrationNote := ''
  else
    RegistrationNote :=
      'The files are installed, but registering the plugin with Claude' + #13#10 +
      'Code did not succeed. Run these two commands in a terminal:' + #13#10#13#10 +
      '  claude plugin marketplace add "' + ExpandConstant('{app}') + '"' + #13#10 +
      '  claude plugin install {#PluginId}@{#MarketplaceName}';
end;

{ The finish page carries the only instruction that matters: Claude reads its
  plugin list once, at startup, so until it is restarted the plugin is invisible
  and the user concludes the install failed. The page therefore leads with the
  restart, numbers the steps, and ends with a prompt they can paste to see the
  tool answer for itself - a check, not a reassurance. The label is stretched to
  the full page height because the default is sized for Inno's own three-line
  message and would clip this. }
procedure CurPageChanged(CurPageID: Integer);
var
  Body: String;
  Step, Grow: Integer;
begin
  { The welcome text is longer than the three lines Inno sizes this label for,
    so give it the rest of the page. Same reason as the finish label below. }
  if CurPageID = wpWelcome then
  begin
    WizardForm.WelcomeLabel2.AutoSize := False;
    WizardForm.WelcomeLabel2.Height :=
      WizardForm.WelcomePage.Height - WizardForm.WelcomeLabel2.Top - ScaleY(8);
    Exit;
  end;

  if CurPageID <> wpFinished then
    Exit;

  WizardForm.FinishedHeadingLabel.Caption := 'Important';

  { "I understand" does not fit the stock Finish button, so widen it leftwards
    and leave the right edge where the user expects to click. }
  WizardForm.NextButton.Caption := 'I understand';
  Grow := ScaleX(104) - WizardForm.NextButton.Width;
  if Grow > 0 then
  begin
    WizardForm.NextButton.Left := WizardForm.NextButton.Left - Grow;
    WizardForm.NextButton.Width := WizardForm.NextButton.Width + Grow;
  end;

  Step := 1;
  if RegistrationNote <> '' then
    { The plugin is not registered, so a restart alone will not help: the two
      commands have to run first and the numbering starts after them. }
    Body := RegistrationNote + #13#10#13#10 +
            'Once that has run, close Claude Code completely and start it' + #13#10 +
            'again: it reads its plugin list only at startup.'
  else
  begin
    Body := 'This is a plugin for Claude Code, and Claude Code reads its' + #13#10 +
            'plugin list only at startup. The session you have open cannot' + #13#10 +
            'see this one yet, and will not until you restart it.' + #13#10#13#10 +
            '   1.  Close Claude Code completely - type /exit in a' + #13#10 +
            '       terminal, or quit the desktop app.' + #13#10 +
            '   2.  Start Claude Code again.';
    Step := 3;
  end;

  if Trim(ApiPage.Values[1]) = '' then
  begin
    Body := Body + #13#10 +
            '   ' + IntToStr(Step) + '.  Type /plugin, pick {#PluginId}, and enter the' + #13#10 +
            '       API URL and key from your email.';
    Step := Step + 1;
  end;

  if ClipboardReady then
    Body := Body + #13#10 +
            '   ' + IntToStr(Step) + '.  Paste this in to prove it is working. It is already' + #13#10 +
            '       copied, so just press Ctrl+V:'
  else
    Body := Body + #13#10 +
            '   ' + IntToStr(Step) + '.  Type this in to prove it is working:';

  Body := Body + #13#10#13#10 +
          '       {#TestPrompt}' + #13#10#13#10 +
          'A reply listing dated reports means you are done.' + #13#10 +
          '"Tool not found" means Claude Code was not fully closed.';

  if DirNote <> '' then
    Body := Body + #13#10#13#10 + DirNote;

  WizardForm.FinishedLabel.AutoSize := False;
  WizardForm.FinishedLabel.WordWrap := True;
  WizardForm.FinishedLabel.Height :=
    WizardForm.FinishedPage.Height - WizardForm.FinishedLabel.Top - ScaleY(8);
  WizardForm.FinishedLabel.Caption := Body;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep <> usUninstall then
    Exit;

  ClaudeExe := FindClaude();
  if ClaudeExe <> '' then
  begin
    RunClaude('plugin uninstall {#PluginId}');
    RunClaude('plugin marketplace remove {#MarketplaceName}');
  end;

  {
    Only ever offered interactively. A silent uninstall has nobody to ask, and
    /SUPPRESSMSGBOXES answers MB_YESNO with Yes, so prompting here would quietly
    destroy a key the user may still need: their own settings file is also read
    by a source build of this tool, and by the next install.
  }
  if FileExists(SettingsFile()) and not UninstallSilent then
    if MsgBox('Also remove your saved API key from' + #13#10 + SettingsFile() + '?',
              mbConfirmation, MB_YESNO) = IDYES then
      DeleteFile(SettingsFile());
end;
