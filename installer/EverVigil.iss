#ifndef MyAppVersion
  #error MyAppVersion must be defined by the release build.
#endif
#ifndef MyVersionInfoVersion
  #error MyVersionInfoVersion must be defined by the release build.
#endif
#ifndef PackageRoot
  #error PackageRoot must be defined by the release build.
#endif
#ifndef RepositoryRoot
  #error RepositoryRoot must be defined by the release build.
#endif
#ifndef InstallerOutputRoot
  #error InstallerOutputRoot must be defined by the release build.
#endif
#ifndef WizardBrandImage
  #error WizardBrandImage must be defined by the release build.
#endif

#include "LegacyCompatibility.generated.iss"

#define MyAppName "EverVigil"
#define MyAppPublisher "Daichi Matsumoto"
#define MyAppUrl "https://github.com/DaichiMatsumoto"
#define MyRepositoryUrl "https://github.com/DaichiMatsumoto/evervigil"
#define RequiredLegalNotice "This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities."
#define MySupportRoot "{localappdata}\EverVigil.Uninstall"
#define MyUninstallRegistryKey LegacyCompatibilityApplicationUninstallRegistrySubKey

#ifdef ResourceAuditBuild
  #ifdef PayloadAuditBuild
    #error ResourceAuditBuild and PayloadAuditBuild cannot be combined.
  #endif
  #ifndef ResourceAuditAppId
    #error ResourceAuditAppId must be defined for a resource-audit build.
  #endif
#endif
#ifdef PayloadAuditBuild
  #ifndef PayloadAuditAppId
    #error PayloadAuditAppId must be defined for a payload-audit build.
  #endif
#endif

[Setup]
#ifdef ResourceAuditBuild
AppId={{{#ResourceAuditAppId}}
#else
  #ifdef PayloadAuditBuild
AppId={{{#PayloadAuditAppId}}
  #else
AppId={{{#LegacyCompatibilityApplicationAppId}}
  #endif
#endif
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppUrl}
AppSupportURL={#MyRepositoryUrl}/issues
AppUpdatesURL={#MyRepositoryUrl}/releases
AppCopyright=Copyright © 2026 Daichi Matsumoto
AppComments=An independent Windows tray utility that keeps Even Terminal running and available.
#ifdef ResourceAuditBuild
DefaultDirName={tmp}\EverVigil.ResourceAudit
#else
  #ifdef PayloadAuditBuild
DefaultDirName={tmp}\EverVigil.PayloadAudit
  #else
DefaultDirName={localappdata}\Programs\EverVigil
  #endif
#endif
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableWelcomePage=no
AlwaysShowDirOnReadyPage=yes
AllowCancelDuringInstall=no
AllowNetworkDrive=no
AllowRootDirectory=no
AllowUNCPath=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=no
CreateAppDir=yes
LicenseFile={#RepositoryRoot}\LICENSE
MinVersion=10.0.22000
#ifdef ResourceAuditBuild
OutputBaseFilename=EverVigil-{#MyAppVersion}-ResourceAudit
#else
  #ifdef PayloadAuditBuild
OutputBaseFilename=EverVigil-{#MyAppVersion}-PayloadAudit
  #else
OutputBaseFilename=EverVigil-{#MyAppVersion}-Setup
  #endif
#endif
OutputDir={#InstallerOutputRoot}
PrivilegesRequired=lowest
RestartApplications=no
SetupIconFile={#RepositoryRoot}\src\EverVigil\Assets\evervigil-placeholder.ico
SetupLogging=yes
SolidCompression=yes
Compression=lzma2/ultra64
UninstallDisplayIcon={app}\EverVigil.exe
UninstallDisplayName={#MyAppName}
#ifdef ResourceAuditBuild
CreateUninstallRegKey=no
UninstallFilesDir={app}
UsePreviousAppDir=no
UsePreviousLanguage=no
#else
  #ifdef PayloadAuditBuild
CreateUninstallRegKey=no
UninstallFilesDir={app}
UsePreviousAppDir=no
UsePreviousLanguage=no
  #else
UninstallFilesDir={#MySupportRoot}
; Keep the new product directory independent from the inherited AppId. The
; prior registration is read explicitly by PreviousInstallDirectory and is
; passed only as -PreviousInstallRoot for controlled migration/retirement.
UsePreviousAppDir=no
UsePreviousLanguage=yes
  #endif
#endif
UninstallLogging=yes
UsePreviousGroup=no
VersionInfoCompany={#MyAppPublisher}
VersionInfoCopyright=Copyright © 2026 Daichi Matsumoto
#ifdef PayloadAuditBuild
VersionInfoDescription={#MyAppName} payload audit extractor
VersionInfoOriginalFileName=EverVigil-{#MyAppVersion}-PayloadAudit.exe
VersionInfoProductName={#MyAppName} Payload Audit
#else
VersionInfoDescription={#MyAppName} guided installer
VersionInfoOriginalFileName=EverVigil-{#MyAppVersion}-Setup.exe
VersionInfoProductName={#MyAppName}
#endif
VersionInfoProductVersion={#MyAppVersion}
VersionInfoVersion={#MyVersionInfoVersion}
WizardImageBackColor=white
WizardImageFile={#WizardBrandImage}
WizardSmallImageBackColor=white
WizardSmallImageFile={#RepositoryRoot}\src\EverVigil\Assets\evervigil-placeholder-source.png
WizardSizePercent=100
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[CustomMessages]
english.SelectDirGuidance=Choose a writable local folder for this user. The default is recommended. System folders, network paths, and temporary folders are rejected.
japanese.SelectDirGuidance=このユーザーが書き込めるローカルフォルダーを選択してください。通常は既定値を推奨します。システム、ネットワーク、一時フォルダーは使用できません。
english.LegalNoticeCaption=Independent project notice
japanese.LegalNoticeCaption=独立プロジェクトに関する通知
english.LegalNoticeDescription=Please read this notice before installing EverVigil.
japanese.LegalNoticeDescription=EverVigilをインストールする前に、次の通知を確認してください。
english.LegalNoticeSubCaption=This notice also appears in the application About screen and release notes.
japanese.LegalNoticeSubCaption=この通知はアプリの情報画面とリリースノートにも掲載されます。
english.InstallingEverVigil=Installing and validating EverVigil. A Windows permission prompt may appear for Tailscale and Firewall configuration...
japanese.InstallingEverVigil=EverVigilを導入して検証しています。Tailscale / Firewall設定時にWindowsの許可確認が表示される場合があります...
english.PowerShellMissing=PowerShell 7 was not found at C:\Program Files\PowerShell\7\pwsh.exe. Install PowerShell 7, then run this setup again.
japanese.PowerShellMissing=PowerShell 7が C:\Program Files\PowerShell\7\pwsh.exe に見つかりません。PowerShell 7を導入してから、もう一度セットアップを実行してください。
english.InstallFailed=Installation did not complete. The previous working version was restored when possible. Details are in the setup log shown below.
japanese.InstallFailed=導入を完了できませんでした。可能な場合は以前の正常版へ復元しています。詳細は下記のセットアップログにあります。
english.KeepDataPrompt=Keep your settings and encrypted connection token?%n%nChoose Yes to keep them for a future reinstall.%nChoose No for complete removal.
japanese.KeepDataPrompt=設定と暗号化済み接続トークンを残しますか？%n%n「はい」: 再インストール用に保持%n「いいえ」: 完全に削除
english.UninstallFailed=System cleanup did not complete, so uninstallation was stopped. No unrelated Tailscale route or Firewall rule was removed.
japanese.UninstallFailed=システム設定の後片付けを完了できなかったため、アンインストールを中止しました。無関係なTailscale経路やFirewallルールは削除していません。
english.CommitCleanupIncomplete=The validated EverVigil installation is active, but final commit evidence cleanup is incomplete. Setup will return recovery-required code 20. Do not delete recovery files; run this exact setup again to resume the same transaction.
japanese.CommitCleanupIncomplete=検証済みEverVigilは有効ですが、最終commit証拠の後片付けが未完了です。Setupは復旧必要code 20を返します。復旧ファイルを削除せず、この同じSetupでもう一度同一transactionを再開してください。

[Files]
#ifdef ResourceAuditBuild
Source: "{#PackageRoot}\payload\EverVigil.exe"; DestDir: "{app}"; Flags: ignoreversion
#else
Source: "{#PackageRoot}\*"; DestDir: "{tmp}\EverVigil.Package"; Flags: dontcopy noencryption recursesubdirs createallsubdirs
Source: "{#PackageRoot}\Uninstall.ps1"; DestDir: "{#MySupportRoot}\Support"; Flags: ignoreversion
Source: "{#PackageRoot}\scripts\Complete-InstallTransaction.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion
Source: "{#PackageRoot}\scripts\InstallTransactionData.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion
Source: "{#PackageRoot}\scripts\Invoke-InteractiveUserTask.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion
Source: "{#PackageRoot}\scripts\Invoke-SystemMaintenance.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion
Source: "{#PackageRoot}\scripts\LegacyCompatibility.generated.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion
Source: "{#PackageRoot}\scripts\Resolve-SafeInstallRoot.ps1"; DestDir: "{#MySupportRoot}\Support\scripts"; Flags: ignoreversion
Source: "{#PackageRoot}\NOTICE.md"; DestDir: "{srcexe}\failure"; DestName: "probe.txt"; Flags: ignoreversion; Check: ShouldInstallFailureProbe
#endif

[Icons]
#ifndef ResourceAuditBuild
Name: "{autoprograms}\{#MyAppName}\{#MyAppName}"; Filename: "{app}\EverVigil.exe"; WorkingDir: "{app}"
Name: "{autoprograms}\{#MyAppName}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
#endif

[Code]
var
#ifndef ResourceAuditBuild
  LegalNoticePage: TOutputMsgMemoWizardPage;
  KeepUserData: Boolean;
#endif
  InstallEverVigilCompleted: Boolean;
  InstallTransactionStarted: Boolean;
  SetupReachedDone: Boolean;
#ifndef ResourceAuditBuild
  UninstallEverVigilRan: Boolean;
#endif
  CommitCleanupIncomplete: Boolean;
  CommitCleanupDetail: String;

function QuoteArgument(const Value: String): String;
begin
  Result := '"' + Value + '"';
end;

procedure LogCapturedOutput(const Output: TExecOutput);
var
  Index: Integer;
begin
  for Index := 0 to GetArrayLength(Output.StdOut) - 1 do
    Log('[evervigil] ' + Output.StdOut[Index]);
  for Index := 0 to GetArrayLength(Output.StdErr) - 1 do
    Log('[evervigil-error] ' + Output.StdErr[Index]);
end;

function LastOutputLine(const Output: TExecOutput): String;
var
  Index: Integer;
begin
  Result := '';
  for Index := GetArrayLength(Output.StdErr) - 1 downto 0 do
  begin
    if Trim(Output.StdErr[Index]) <> '' then
    begin
      Result := Trim(Output.StdErr[Index]);
      Exit;
    end;
  end;
  for Index := GetArrayLength(Output.StdOut) - 1 downto 0 do
  begin
    if Trim(Output.StdOut[Index]) <> '' then
    begin
      Result := Trim(Output.StdOut[Index]);
      Exit;
    end;
  end;
end;

function PowerShellPath: String;
begin
  Result := ExpandConstant('{pf}\PowerShell\7\pwsh.exe');
end;

function HasInstallTransactionTemporary(const Root: String): Boolean;
var
  FindRec: TFindRec;
begin
  Result := FindFirst(
    AddBackslash(Root) +
      '{#LegacyCompatibilityDataTransactionJournalFileName}.new-*',
    FindRec);
  if Result then
    FindClose(FindRec);
end;

function HasPersistentData(const Root: String): Boolean;
begin
  Result :=
    FileExists(AddBackslash(Root) + '{#LegacyCompatibilityDataSettingsFileName}') or
    FileExists(AddBackslash(Root) + '{#LegacyCompatibilityDataProtectedTokenFileName}') or
    FileExists(AddBackslash(Root) + '{#LegacyCompatibilityDataTransactionJournalFileName}') or
    HasInstallTransactionTemporary(Root) or
    FileExists(AddBackslash(Root) + '{#LegacyCompatibilityDataAppliedSystemConfigurationFileName}') or
    FileExists(AddBackslash(Root) + '{#LegacyCompatibilityDataSystemConfigurationRequiredFileName}') or
    FileExists(AddBackslash(Root) + '{#LegacyCompatibilityDataDiagnosticLoggingMarkerFileName}') or
    DirExists(AddBackslash(Root) + '{#LegacyCompatibilityDataTransactionRecoveryDirectoryName}');
end;

function ActiveDataRoot: String;
var
  CurrentRoot: String;
  LegacyRoot: String;
  CurrentHasState: Boolean;
  LegacyHasState: Boolean;
begin
  CurrentRoot := ExpandConstant('{localappdata}\EverVigil');
  LegacyRoot := ExpandConstant(
    '{localappdata}\{#LegacyCompatibilityApplicationDataRootRelativeToLocalAppData}');
  CurrentHasState := HasPersistentData(CurrentRoot);
  LegacyHasState := HasPersistentData(LegacyRoot);
  if CurrentHasState and LegacyHasState then
    RaiseException(
      'Both current and legacy application data contain persistent state. ' +
      'Resolve the interrupted migration before continuing.');
  if LegacyHasState then
    Result := LegacyRoot
  else
    Result := CurrentRoot;
end;

function InstallTransactionPath: String;
begin
  Result := AddBackslash(ActiveDataRoot) +
    '{#LegacyCompatibilityDataTransactionJournalFileName}';
end;

function InstallTransactionScriptPath: String;
begin
  Result := ExpandConstant(
    '{tmp}\EverVigil.Package\scripts\Complete-InstallTransaction.ps1');
end;

procedure InitializeWizard;
begin
#ifndef ResourceAuditBuild
  LegalNoticePage := CreateOutputMsgMemoPage(
    wpWelcome,
    CustomMessage('LegalNoticeCaption'),
    CustomMessage('LegalNoticeDescription'),
    CustomMessage('LegalNoticeSubCaption'),
    '{#RequiredLegalNotice}');
#endif
end;

function RunInstallTransaction(const Action: String; var Detail: String): Boolean;
var
  Executed: Boolean;
  Parameters: String;
  ResultCode: Integer;
  Output: TExecOutput;
begin
  Detail := '';
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    QuoteArgument(InstallTransactionScriptPath) + ' -Action ' + Action +
    ' -TransactionPath ' + QuoteArgument(InstallTransactionPath);
  try
    Executed := ExecAndCaptureOutput(
      PowerShellPath,
      Parameters,
      ExtractFileDir(InstallTransactionScriptPath),
      SW_SHOWNORMAL,
      ewWaitUntilTerminated,
      ResultCode,
      Output);
  except
    Detail := GetExceptionMessage;
    Result := False;
    Exit;
  end;
  LogCapturedOutput(Output);
  Detail := LastOutputLine(Output);
  Result := Executed and (ResultCode = 0);
end;

function ExecuteInstallWorker(
  const InstallScript: String;
  const Parameters: String;
  var ResultCode: Integer;
  var Output: TExecOutput;
  var Detail: String): Boolean;
begin
  Detail := '';
  try
    Result := ExecAndCaptureOutput(
      PowerShellPath,
      Parameters,
      ExtractFileDir(InstallScript),
      SW_SHOWNORMAL,
      ewWaitUntilTerminated,
      ResultCode,
      Output);
  except
    Detail := GetExceptionMessage;
    Result := False;
    Exit;
  end;
  LogCapturedOutput(Output);
  Log(Format('EverVigil install worker exit code: %d', [ResultCode]));
end;

function IsPowerShellInternalRuntimeFailure(const ResultCode: Integer): Boolean;
begin
  { 0x80131506 / System.ExecutionEngineException, represented as signed Int32. }
  Result := ResultCode = -2146233082;
end;

function HasUnresolvedInstallTransaction: Boolean;
begin
  Result := FileExists(InstallTransactionPath) or
    HasInstallTransactionTemporary(ActiveDataRoot);
end;

function InitializeSetup: Boolean;
#ifdef PayloadAuditBuild
var
  AuditRoot: String;
  AuditScript: String;
  Parameters: String;
  Executed: Boolean;
  ResultCode: Integer;
  Output: TExecOutput;
#endif
begin
#ifdef PayloadAuditBuild
  Result := False;
  AuditRoot := ExpandConstant('{param:AUDITEXTRACT|}');
  if AuditRoot = '' then
  begin
    Log('Payload audit build requires /AUDITEXTRACT.');
    Exit;
  end;

  try
    ExtractTemporaryFiles('{tmp}\EverVigil.Package\*');
    AuditScript := ExpandConstant(
      '{tmp}\EverVigil.Package\scripts\Export-InstallerPayload.ps1');
    Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
      QuoteArgument(AuditScript) + ' -SourceRoot ' +
      QuoteArgument(ExpandConstant('{tmp}\EverVigil.Package')) +
      ' -DestinationRoot ' + QuoteArgument(AuditRoot);
    Executed := ExecAndCaptureOutput(
      PowerShellPath,
      Parameters,
      ExtractFileDir(AuditScript),
      SW_SHOWNORMAL,
      ewWaitUntilTerminated,
      ResultCode,
      Output);
    LogCapturedOutput(Output);
    if (not Executed) or (ResultCode <> 0) then
      Log('Audit extraction failed: ' + LastOutputLine(Output));
  except
    Log('Audit extraction failed: ' + GetExceptionMessage);
  end;
  Result := False;
#else
  Result := True;
  if ExpandConstant('{param:AUDITEXTRACT|}') <> '' then
  begin
    Log('/AUDITEXTRACT is rejected by this build.');
    Result := False;
  end;
#endif
end;

function SetupLogDescription: String;
begin
  Result := ExpandConstant('{log}');
  if Result = '' then
    Result := ExpandConstant('{tmp}');
end;

function PreviousInstallDirectory: String;
begin
  Result := '';
  RegQueryStringValue(
    HKCU,
    '{#MyUninstallRegistryKey}',
    'InstallLocation',
    Result);
  Result := RemoveBackslashUnlessRoot(Result);
end;

function ShouldInstallFailureProbe: Boolean;
begin
  Result := CompareText(
    ExpandConstant('{param:FAILINNOFILECOPY|0}'),
    '1') = 0;
end;

function InstallEverVigil: String;
var
  InstallScript: String;
  Parameters: String;
  PreviousInstallRoot: String;
  ResultCode: Integer;
  Output: TExecOutput;
  Detail: String;
begin
  Result := '';
  if InstallEverVigilCompleted then
    Exit;

  WizardForm.StatusLabel.Caption := CustomMessage('InstallingEverVigil');
  try
    ExtractTemporaryFiles('{tmp}\EverVigil.Package\*');
  except
    Result := CustomMessage('InstallFailed') + #13#10 + #13#10 +
      GetExceptionMessage + #13#10 + #13#10 + SetupLogDescription;
    Exit;
  end;
  if not RunInstallTransaction('Recover', Detail) then
  begin
    Result := CustomMessage('InstallFailed') + #13#10 + #13#10 +
      'Pending transaction recovery failed: ' + Detail + #13#10 + #13#10 +
      SetupLogDescription;
    Exit;
  end;
  if HasUnresolvedInstallTransaction then
  begin
    Result := CustomMessage('InstallFailed') + #13#10 + #13#10 +
      'Pending transaction recovery requires manual attention.' + #13#10 + #13#10 +
      SetupLogDescription;
    Exit;
  end;
  InstallScript := ExpandConstant('{tmp}\EverVigil.Package\Install.ps1');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    QuoteArgument(InstallScript) + ' -InstallRoot ' + QuoteArgument(ExpandConstant('{app}')) +
    ' -TargetVersion ' + QuoteArgument('{#MyAppVersion}') +
    ' -DeferCommit';
  PreviousInstallRoot := PreviousInstallDirectory;
  if PreviousInstallRoot <> '' then
    Parameters := Parameters + ' -PreviousInstallRoot ' + QuoteArgument(PreviousInstallRoot);
  if not ExecuteInstallWorker(
    InstallScript,
    Parameters,
    ResultCode,
    Output,
    Detail) then
  begin
    Result := CustomMessage('InstallFailed') + #13#10 + #13#10 +
      Detail + #13#10 + #13#10 + SetupLogDescription;
    Exit;
  end;

  if IsPowerShellInternalRuntimeFailure(ResultCode) then
  begin
    Log(
      'PowerShell terminated with 0x80131506 before the install worker ' +
      'completed. Recovering the authenticated transaction before one retry.');
    if not RunInstallTransaction('Recover', Detail) then
    begin
      Result := CustomMessage('InstallFailed') + #13#10 + #13#10 +
        'Recovery after the PowerShell runtime failure failed: ' + Detail + #13#10 + #13#10 +
        SetupLogDescription;
      Exit;
    end;
    if HasUnresolvedInstallTransaction then
    begin
      Result := CustomMessage('InstallFailed') + #13#10 + #13#10 +
        'Recovery after the PowerShell runtime failure requires manual attention.' + #13#10 + #13#10 +
        SetupLogDescription;
      Exit;
    end;
    if not ExecuteInstallWorker(
      InstallScript,
      Parameters,
      ResultCode,
      Output,
      Detail) then
    begin
      Result := CustomMessage('InstallFailed') + #13#10 + #13#10 +
        Detail + #13#10 + #13#10 + SetupLogDescription;
      Exit;
    end;
    if IsPowerShellInternalRuntimeFailure(ResultCode) then
    begin
      Log(
        'PowerShell terminated with 0x80131506 again. No further retry will be attempted; ' +
        'recovering the authenticated transaction before setup exits.');
      if not RunInstallTransaction('Recover', Detail) then
      begin
        Result := CustomMessage('InstallFailed') + #13#10 + #13#10 +
          'Recovery after the repeated PowerShell runtime failure failed: ' + Detail + #13#10 + #13#10 +
          SetupLogDescription;
        Exit;
      end;
      if HasUnresolvedInstallTransaction then
      begin
        Result := CustomMessage('InstallFailed') + #13#10 + #13#10 +
          'Recovery after the repeated PowerShell runtime failure requires manual attention.' + #13#10 + #13#10 +
          SetupLogDescription;
        Exit;
      end;
      Result := CustomMessage('InstallFailed') + #13#10 + #13#10 +
        'PowerShell encountered the same internal runtime failure again. ' +
        'The installation transaction was recovered safely and was not retried again.' + #13#10 + #13#10 +
        SetupLogDescription;
      Exit;
    end;
  end;

  if (ResultCode <> 0) or
    (not FileExists(ExpandConstant('{app}\EverVigil.exe'))) or
    (not FileExists(InstallTransactionPath)) then
  begin
    Detail := LastOutputLine(Output);
    if Detail <> '' then
      Detail := #13#10 + #13#10 + Detail;
    Result := CustomMessage('InstallFailed') + Detail + #13#10 + #13#10 +
      SetupLogDescription;
    Exit;
  end;
  InstallEverVigilCompleted := True;
  InstallTransactionStarted := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
#ifndef ResourceAuditBuild
  if not FileExists(PowerShellPath) then
  begin
    Result := CustomMessage('PowerShellMissing');
    Exit;
  end;
  Result := InstallEverVigil;
  if (Result = '') and
    (CompareText(ExpandConstant('{param:FAILAFTERPREPARE|0}'), '1') = 0) then
    Result := 'Intentional transaction rollback requested after preparation.';
#endif
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Detail: String;
begin
  if not InstallTransactionStarted then
    Exit;
  if CurStep = ssPostInstall then
  begin
    if FileExists(InstallTransactionPath) and
      (not RunInstallTransaction('Seal', Detail)) then
      RaiseException('Could not seal the install transaction: ' + Detail);
  end
  else if CurStep = ssDone then
  begin
    SetupReachedDone := True;
    if FileExists(InstallTransactionPath) then
    begin
      if not RunInstallTransaction('Commit', Detail) then
      begin
        CommitCleanupIncomplete := True;
        CommitCleanupDetail := Detail;
        Log('Install transaction commit cleanup is incomplete: ' + Detail);
        MsgBox(
          CustomMessage('CommitCleanupIncomplete') + #13#10 + #13#10 + Detail,
          mbError,
          MB_OK);
      end;
    end;
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  if CommitCleanupIncomplete then
    Result := 20
  else
    Result := 0;
end;

procedure DeinitializeSetup;
var
  Action: String;
  Detail: String;
  FinalizationSucceeded: Boolean;
begin
  if (not InstallTransactionStarted) or
    (not FileExists(InstallTransactionPath)) then
    Exit;
  if SetupReachedDone then
    Action := 'Commit'
  else
    Action := 'Rollback';
  FinalizationSucceeded := RunInstallTransaction(Action, Detail);
  if not FinalizationSucceeded then
  begin
    Log('Install transaction finalization failed: ' + Detail);
    SuppressibleMsgBox(
      CustomMessage('InstallFailed') + #13#10 + #13#10 + Detail,
      mbError,
      MB_OK,
      IDOK);
  end;
  if SetupReachedDone and FinalizationSucceeded and
    (not FileExists(InstallTransactionPath)) then
  begin
    CommitCleanupIncomplete := False;
    CommitCleanupDetail := '';
  end;
end;

function InitializeUninstall: Boolean;
#ifndef ResourceAuditBuild
var
  Response: Integer;
#endif
begin
#ifdef ResourceAuditBuild
  Result := True;
#else
  Response := SuppressibleMsgBox(
    CustomMessage('KeepDataPrompt'),
    mbConfirmation,
    MB_YESNOCANCEL,
    IDYES);
  if Response = IDCANCEL then
  begin
    Result := False;
    Exit;
  end;
  KeepUserData := Response = IDYES;
  Result := True;
#endif
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
#ifndef ResourceAuditBuild
var
  Executed: Boolean;
  UninstallScript: String;
  Parameters: String;
  ResultCode: Integer;
  Output: TExecOutput;
  Detail: String;
#endif
begin
#ifdef ResourceAuditBuild
  Exit;
#else
  if (CurUninstallStep <> usUninstall) or UninstallEverVigilRan then
    Exit;
  UninstallEverVigilRan := True;

  UninstallScript := ExpandConstant('{#MySupportRoot}\Support\Uninstall.ps1');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    QuoteArgument(UninstallScript) + ' -InstallRoot ' + QuoteArgument(ExpandConstant('{app}'));
  if KeepUserData then
    Parameters := Parameters + ' -KeepData';
  try
    Executed := ExecAndCaptureOutput(
      PowerShellPath,
      Parameters,
      ExtractFileDir(UninstallScript),
      SW_SHOWNORMAL,
      ewWaitUntilTerminated,
      ResultCode,
      Output);
  except
    SuppressibleMsgBox(
      CustomMessage('UninstallFailed') + #13#10 + #13#10 +
        GetExceptionMessage,
      mbError,
      MB_OK,
      IDOK);
    Abort;
  end;
  LogCapturedOutput(Output);
  if (not Executed) or (ResultCode <> 0) then
  begin
    Detail := LastOutputLine(Output);
    if Detail <> '' then
      Detail := #13#10 + #13#10 + Detail;
    SuppressibleMsgBox(
      CustomMessage('UninstallFailed') + Detail,
      mbError,
      MB_OK,
      IDOK);
    Abort;
  end;
#endif
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpSelectDir then
    WizardForm.SelectDirLabel.Caption := CustomMessage('SelectDirGuidance');
end;
