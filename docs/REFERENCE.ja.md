# EverVigil 技術リファレンス

[English](REFERENCE.en.md) | [利用ガイド](README.ja.md) | [技術概要](TECHNICAL_OVERVIEW.ja.md) | [リポジトリ](https://github.com/DaichiMatsumoto/evervigil)

対象release: `2.1.1`

## Runtime topology

```text
Tailnet client -> Tailscale Serve :3456
               -> 127.0.0.1:3457 Even Terminal
               -> 127.0.0.1:8765 Codex app-server

EverVigil -> launcher -> Node.js -> 別途導入済みEven Terminal / Codex
```

Tailscale ServeはTailnet-onlyでFunnelを使わず、Tailnet ACLに依存します。
EverVigilはCodex認証情報を読取り・保存しません。

## 配置

| 種別 | パス |
|---|---|
| program | setupで選択。既定`%LOCALAPPDATA%\Programs\EverVigil` |
| 設定 | `%LOCALAPPDATA%\EverVigil\settings.json` |
| 適用済みsystem状態 | `%LOCALAPPDATA%\EverVigil\applied-system-configuration.json` |
| 起動禁止marker | `%LOCALAPPDATA%\EverVigil\system-configuration-required` |
| DPAPI token | `%LOCALAPPDATA%\EverVigil\token.dat` |
| ログ | `%LOCALAPPDATA%\EverVigil\Logs\evervigil.log` |
| Startup shortcut | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\EverVigil.lnk` |

設定、token、ログ、transaction状態、machine-local設定をRelease assetへ含めません。

## 既定設定

| 項目 | 既定値 / 意味 |
|---|---|
| 表示言語 | Windows表示言語。日本語なら日本語、それ以外は英語 |
| Display name | 現在のWindows machine名 |
| Tailscale host | 保護ブローカー台帳から読むread-onlyのTailscale Self DNS名。machine名へfallbackしない |
| Tailscale CLI | read-only固定path `C:\Program Files\Tailscale\tailscale.exe`。任意実行fileは拒否 |
| Serve port | `3456` |
| Even Terminal backend | `127.0.0.1:3457` |
| Codex app-server | `127.0.0.1:8765` |
| Project directory | 現在のユーザーprofile |
| Health interval | 30秒 |
| Provider / Tailnet check | 300秒 |
| Startup timeout | 120秒 |
| Stable run | 600秒 |
| Failure threshold | 3回 |
| Log limit | 5 MB x 3世代 |
| Secret reveal | 約60秒 |
| Clipboard clear | 既定60秒 |

## Command line

| option | 用途 |
|---|---|
| `--background` | windowを表示せず通知領域で起動 |
| `--health-check` | loopback backend/provider、保護された現在のTailscale Self identity、現在の正確なTailnet-only Serve rootを検査。全成功時0 |
| `--shutdown` | current-user instanceを正常終了 |
| `--register-startup` | `EverVigil` Startup shortcutを登録 |
| `--unregister-startup` | `EverVigil` Startup shortcutを解除 |
| `--force-start-service` | 保存設定に関係なくmanaged serviceを今回だけ開始 |

`--bridge-launcher`、system maintenance、transaction recovery、audit modeは
内部interfaceです。手動実行しないでください。

## ServeとFirewallの所有権

既定Serve commandは次のとおりです。

```powershell
tailscale serve --yes --bg --http 3456 http://127.0.0.1:3457
```

変更前にcanonical ProgramData brokerが`tailscale serve status --json`を確認し、root
mappingをACL保護済みSID別applied台帳と照合します。不一致または曖昧なmappingはunownedとして
変更しません。Windows Firewall block ruleはユーザー識別可能にし、完全identityと保護所有権
証拠を検証した後だけ削除します。medium-integrity clientはPID/SID/session/nonceを結合した
named pipeでbrokerへ認証します。初回installer Applyだけは、検証済みpackage brokerが同じ昇格
process内でcanonical imageの導入とApplyを行います。以後の操作はcanonical brokerだけが実行し、
通知領域supervisor、PowerShell script、child applicationは通常権限を維持します。

## TokenとQRの取扱い

`TokenUtility`は16 CSPRNG bytesを生成し、32桁の小文字16進文字列へencodeします。
`TokenStore`はapplication-specific entropy label `EverVigil/token/v1`付きDPAPI
`CurrentUser`と制限ACLでtokenを保護します。bridgeへは`BRIDGE_TOKEN`で渡し、
command-line argumentへ含めません。

QRCoderは接続URLをローカル描画します。表示には明示操作が必要で、約60秒後および
window非アクティブ時に隠します。copy時はclipboard履歴を警告します。URL query token、
Bearer credential、既知token、32桁16進token形式値を秘匿化します。

## 手動更新とv1.2.1互換性

自動更新機能はありません。GitHub Release installerを手動取得し、SHA-256を確認して
上書き実行します。binaryは未署名でSmartScreenが警告する場合があります。

v1.2.1からのin-place upgradeに限り、旧AppIdと必要な暗号・path互換情報を専用
`LegacyCompatibility`境界で保持します。これらはユーザー向け名称ではありません。
transactionは設定、暗号化token bytes、自動起動設定を保持し、EverVigil正常化後に
所有確認済み旧resourceだけを撤去します。rollbackは検証済みsnapshotと旧稼働状態を復元します。

新規導入は上表のEverVigil pathを使用します。検証済みv1.2.1 upgradeでは安全な互換性に
必要な間、旧data root、DPAPI entropy、同期名を使用する場合があります。tokenを手動移動
しないでください。currentと旧rootの両方に永続状態がある場合は曖昧としてfail-closedにします。

## Uninstall contract

uninstallerは所有processを停止し、所有するServe、Firewall、Startup、shortcut、support、
transaction、一時resource、検証済みprogramだけを削除し、設定とtokenの保持・削除を
選択可能にします。Tailscale、Node.js、Codex、`@evenrealities/even-terminal`、無関係な
経路・rule、未検証directoryは削除しません。

## ソース検証

repository rootで次を実行します。

```powershell
dotnet restore .\EverVigil.sln
dotnet build .\EverVigil.sln -c Release --no-restore
dotnet format .\EverVigil.sln --verify-no-changes --no-restore
dotnet run --project .\tests\EverVigil.Tests\EverVigil.Tests.csproj -c Release --no-build
dotnet run --project .\tests\EverVigil.Broker.Tests\EverVigil.Broker.Tests.csproj -c Release --no-build
.\tests\Test-Repository.ps1
.\tests\Test-SystemMaintenance.ps1
.\tests\Test-InstallTransaction.ps1
.\scripts\Test-NuGetVulnerabilities.ps1 -SolutionPath .\EverVigil.sln
.\scripts\New-PlaceholderIcon.ps1 -Check
.\scripts\Test-ReleaseVersion.ps1 -Version 2.1.1
.\scripts\Build-Release.ps1 -Version 2.1.1
```

Release承認にはsource、staged file、binary、installer展開内容、VersionInfo、icon、notice、
禁止文字列、deny-listの各scanも必要です。対象Windows環境で未実施のbuild・scanは
成功扱いせず、未実施として報告します。

private draft RCの作成には、同じcandidate manifestの`sourceSha`、version、installer
SHA-256へ結び付いた本番installer実機監査も必要です。Actions jobはcontrollerだけで動き、
candidateを実行しません。controllerとは別の専用ephemeral Windows 11 Pro物理targetを
AMDとIntelで1台ずつ使用し、両方のreportが全check成功、failure 0、skip 0でなければ
publish jobは開始しません。監査対象はclean installと正確な
`CONFIGURATION REQUIRED`状態、通常runtime（Windows login startup、tray、Even Terminal、
Codex app-server、異常終了後restart、Tailscale Serve所有権、QR接続、reveal timeout、
token永続化、normal update）、v1.2.1の既定／custom path・port移行、commit境界前rollback、
境界後forward recovery、Start menu・ARP・support登録、設定保持／完全uninstall、別の
administrator資格情報を使うover-the-shoulder昇格、residue／system snapshotです。

clean installのreport契約は`schemaVersion=2`です。report直下の`cleanInstall`と
`clean-install-execution-attestation` JSON evidenceは、同じexact objectを保持します。
外部監査harnessの既存CLIは変更しませんが、AMD／Intelの両方でv2を出力できなければ
旧schemaを受理せずfail-closedにします。`cleanInstall`は次をすべて証明します。

- 実行前に現行／legacy data root、install root、transaction journal／temporary file、
  `C:\ProgramData\EverVigil` protected broker root全体（`protectedBrokerRootAbsent=true`）、
  protected broker executable／receipt、Start menu、ARP、uninstall supportが存在しない。
- candidate名とSHA-256へ実行前後とも一致する本番Setup pathをstandard userで直接実行し、
  HKCU install、`PrepareToInstall`成功、Setup exit 0である。`/AUDITEXTRACT`、resource-audit
  build、compatibility mode、administrative install modeは本番実行の代替にできない。
- medium-integrity clientからhigh-integrity brokerへの二段階authenticated pipeが成功し、
  `broker-authenticated-pipe-roundtrip`はbootstrap=`CanonicalReady`、canonical status=`NoChange`、
  両exit 0、pipe接続true、authentication exit 3の発生0を要求する。
- 実際の`pwsh.exe`／`coreclr.dll` path、version、SHA-256を記録し、Setup lifecycle全体の
  Application Error Event 1000、.NET Runtime Event 1023、WER Event 1001、`0x80131506`を0件にする。
- exact version、`CONFIGURATION REQUIRED`、installed executable、Start menu、ARP、support、
  完了済みtransactionをpost-stateで確認し、journal／temporary file、installer error、
  `PrepareToInstall` failure、legacy data rootが残らない。

各targetにはGitHub Actions runnerを登録せず、GitHub job token、runner登録credential、
tailnet auth keyを配置しません。外部監査harnessは固定hashと保護済みProgram Files pathを
検証したcontroller上でだけ動き、credentialへ到達できない別targetへcandidateを渡します。
reportはcontrollerとtargetの別fingerprint/session、target側credential不存在、clean snapshot、
物理machine、監査後のtarget session退役を証明し、same-host実行を拒否します。

証拠artifactはUTF-8のJSON・log・textに限定し、QR画像、connection URL、Bearer値、token
query、既知canary、token形式値を含めません。各fileはreport内のlengthとSHA-256へ結び、
write tokenを持たないcontroller監査jobで検証します。GitHub write tokenを持つpublish jobはrepositoryを
checkoutせず、candidate、AMD report、Intel reportのstrict JSONと全file hashだけを再検証
します。専用runnerまたは固定hashの外部監査harnessが利用不能ならgateはfail-closedのままで、
未実施を成功扱いしません。
