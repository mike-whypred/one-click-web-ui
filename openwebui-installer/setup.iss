; ============================================================================
;  setup.iss  -  Inno Setup wrapper for the Open WebUI installer (stretch goal)
;
;  Compiles the openwebui-installer folder into a single setup.exe with a
;  progress bar and a proper Add/Remove Programs entry. This is the artifact you
;  can later CODE SIGN to avoid most SmartScreen friction (see "Signing" below).
;
;  What it does:
;    1. Copies the installer scripts (install.ps1, launch.ps1.template, the .bat
;       files, README, CHANGELOG) into a per-user program folder.
;    2. Runs install.ps1 as a post-install step, which does the real work
;       (Ollama, bundled Python via uv, the model, the launcher, the desktop
;       shortcut). The console stays visible so the multi-GB model download
;       shows progress instead of looking frozen.
;    3. Creates a Start Menu icon that launches Open WebUI hidden (via wscript +
;       the generated launch-hidden.vbs). The desktop shortcut is created by
;       install.ps1 itself, so we do not duplicate it here.
;    4. On uninstall, runs uninstall.ps1 to remove the runtime folder and ask
;       (via an Inno dialog) whether to delete the downloaded models.
;
;  Per-user, no admin: PrivilegesRequired=lowest matches our no-UAC design, so
;  this never triggers an elevation prompt. Everything installs under the user's
;  LocalAppData, exactly like the .bat entry point does.
;
;  Build: install Inno Setup 6 (https://jrsoftware.org/isdl.php), open this file
;  in the Inno Setup Compiler, and click Compile. Output: dist\setup.exe.
;  Requires Inno Setup 6.3+ for x64compatible; on older 6.x use "x64" instead.
;
;  No em dashes in any user-facing text (Inno messages or comments).
; ============================================================================

#define AppName "Open WebUI"
; AppVersion can be overridden from the command line by the CI build
; (ISCC /DAppVersion=1.2.3). Falls back to this default for local compiles.
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppPublisher "Open WebUI Installer"

[Setup]
; A stable AppId keeps upgrades and the Add/Remove Programs entry consistent.
; Generate your own GUID for a real release (Inno: Tools, Generate GUID).
AppId={{B8E9F2A1-4C7D-4E3B-9A6F-1D2C3B4A5E6F}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
; No UAC: install entirely in the user's profile.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\OpenWebUI
DisableProgramGroupPage=yes
; 64-bit Windows 10/11 only. 10.0.10240 is Windows 10 RTM.
MinVersion=10.0.10240
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Output a single setup.exe under dist\.
OutputDir=dist
OutputBaseFilename=setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Shown in Add/Remove Programs; points at the launcher's icon source.
UninstallDisplayIcon={sys}\SHELL32.dll,14
UninstallDisplayName={#AppName}
; If you have a signing certificate, uncomment and configure a SignTool (see
; "Signing" at the bottom) so the compiled setup.exe and uninstaller are signed:
; SignTool=mysigner
; SignedUninstaller=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Copy the whole installer payload into {app}. install.ps1 reads
; launch.ps1.template from its own folder ({app}), so they must travel together.
Source: "install.ps1";           DestDir: "{app}"; Flags: ignoreversion
Source: "launch.ps1.template";   DestDir: "{app}"; Flags: ignoreversion
Source: "Install-OpenWebUI.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "Uninstall-OpenWebUI.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "uninstall.ps1";         DestDir: "{app}"; Flags: ignoreversion
Source: "README.md";             DestDir: "{app}"; Flags: ignoreversion isreadme
Source: "CHANGELOG.md";          DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Start Menu entry. Targets wscript + the hidden-launch .vbs that install.ps1
; generates under LocalAppData\OpenWebUI. The target does not exist yet when
; this icon is created (install.ps1 runs afterward), which is fine; Inno does
; not require the target to exist at creation time.
Name: "{autoprograms}\Open WebUI"; Filename: "{sys}\wscript.exe"; \
    Parameters: """{localappdata}\OpenWebUI\launch-hidden.vbs"""; \
    IconFilename: "{sys}\SHELL32.dll"; IconIndex: 14; \
    Comment: "Start Open WebUI (local AI chat)"

[Code]
{ Run install.ps1 after files are copied. We use Exec so we can read the exit
  code and surface a friendly message on failure, pointing the user at the logs.
  The PowerShell console is left visible (SW_SHOWNORMAL) so the long download
  shows progress rather than appearing to hang. }
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Params: string;
  LogPath: string;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption :=
      'Setting up Open WebUI. This downloads several large files (including the' +
      ' AI model) and can take a while. Please leave it running.';

    Params := '-NoProfile -ExecutionPolicy Bypass -File "' +
              ExpandConstant('{app}\install.ps1') + '"';

    if not Exec('powershell.exe', Params, '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then
    begin
      MsgBox('Could not start the setup step. Please make sure Windows PowerShell' + #13#10 +
             'is available, then run the installer again.', mbCriticalError, MB_OK);
      Abort;
    end;

    if ResultCode <> 0 then
    begin
      LogPath := ExpandConstant('{localappdata}\OpenWebUI\logs');
      MsgBox('The setup step did not finish successfully.' + #13#10#13#10 +
             'A log file with details is in:' + #13#10 + LogPath + #13#10#13#10 +
             'Common causes: no internet during first install, not enough disk' + #13#10 +
             'space, or antivirus blocking a step. Fix that and run setup again.',
             mbCriticalError, MB_OK);
      Abort;
    end;
  end;
end;

{ On uninstall, drive uninstall.ps1 non-interactively. We ask once, via an Inno
  dialog, whether to also delete the (potentially large) downloaded models, then
  pass the answer through as a switch since the script cannot prompt from here. }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  Params: string;
  RemoveModels: Boolean;
begin
  if CurUninstallStep = usUninstall then
  begin
    RemoveModels := MsgBox('Also delete the downloaded AI models to reclaim disk' + #13#10 +
                           'space? Choose No to keep them for later use.',
                           mbConfirmation, MB_YESNO) = IDYES;

    Params := '-NoProfile -ExecutionPolicy Bypass -File "' +
              ExpandConstant('{app}\uninstall.ps1') + '" -NonInteractive';
    if RemoveModels then
      Params := Params + ' -RemoveModels';

    Exec('powershell.exe', Params, '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode);
    { uninstall.ps1 removes the runtime folder and desktop shortcut; Inno then
      removes the program folder and the Start Menu icon. }
  end;
end;

{ ============================================================================
  Signing (the point of this wrapper)

  An unsigned setup.exe still triggers SmartScreen, but a single signed .exe is
  far easier for users than "More info > Run anyway" on a raw .bat, and it
  builds reputation over time. To sign:

    1. Obtain a code-signing certificate (ideally an EV or OV cert from a CA).
    2. Define a SignTool in the Inno Setup IDE (Tools, Configure Sign Tools):
         Name:    mysigner
         Command: "C:\path\to\signtool.exe" sign /fd sha256 /tr
                  http://timestamp.digicert.com /td sha256 /a $f
    3. Uncomment the SignTool and SignedUninstaller lines in [Setup] above.
    4. Recompile. Inno signs setup.exe (and the embedded uninstaller).
  ============================================================================ }
