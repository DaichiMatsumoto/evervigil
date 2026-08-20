# EverVigil 技術概要

[English](TECHNICAL_OVERVIEW.en.md) | [利用ガイド](README.ja.md) | [技術リファレンス](REFERENCE.ja.md) | [リポジトリ](https://github.com/DaichiMatsumoto/evervigil)

本書はEverVigil v2.0.0のarchitectureとsecurity modelを説明します。

## 1. Architecture（アーキテクチャ）

```text
Even client / G2
  -> Tailscale Tailnet
  -> Tailscale Serve :3456
  -> 127.0.0.1:3457 Even Terminal
  -> 127.0.0.1:8765 Codex app-server

Windows login
  -> EverVigil Startup entry
  -> 通知領域アプリ（medium integrity）
  -> supervised launcher / Job Object
  -> 別途導入済みNode.js / Even Terminal / Codex

system構成request
  -> client PID / SID / session / nonceを結合した認証済みnamed pipe
  -> canonical EverVigil.Broker.exe（固定操作時だけhigh integrity）
  -> 保護ProgramData journal / Tailscale Serve / Windows Firewall
```

EverVigilはユーザー単位で動く.NET 8 Windows通知領域アプリです。local dependencyを
制御しますが、`@evenrealities/even-terminal`、Codex、Node.js、Tailscaleをbundle、
fork、patch、再配布しません。telemetry、独自cloud backend、外部relayも追加しません。

製品名、実行ファイル、自動起動entry、導入folder、Start menu folder、process、
window titleはすべて`EverVigil`です。旧製品との互換性に必要なidentifierは内部の
移行dataであり、製品名ではありません。

## 2. Process supervision（プロセス監督）

EverVigilはconsoleを表示せずにEven Terminal bridgeとCodex providerを起動します。
bridge launcherを子孫生成前にWindows Job Objectへ所属させるため、再起動・更新・
rollback・uninstall時に所有するprocess treeを停止できます。

launcherとNode bridgeは、active data root配下でACLを制限した`BridgeHost`を非公開の
process current directoryとして使用します。これはproject設定ではありません。
EverVigilは`PROJECT_DIR`をexportせず、global `--cwd`も指定しません。taskごとの要求済み／
保存済みworking directoryは、別途導入したproviderが管理します。

token付きhealth requestはloopback backendだけへ送信します。Tailnetの準備状態はさらに、
保護ブローカー台帳とactiveなport/Tailscale executableの一致、現在この端末へ割り当てられた
Tailscale address、記録済みTailscale Self名の全DNS応答との一致、現在のServe statusに保護対象の
正確なroot proxyが存在しFunnelが無効であることを必要とします。Serve検査はread-onlyかつ
非昇格です。設定値やremote hostへbridge tokenを送るhealth checkはありません。異常終了には上限付き指数backoffを適用し、
安定稼働後に失敗数をresetし、閾値超過時は
無限crash loopを抑制します。Windows login時の自動起動は管理windowを表示せず
通知領域アプリを開始します。通常監視は一般ユーザー権限で動き、常時昇格しません。

## 3. Tailscale Serve configuration（Tailscale Serve構成）

既定操作は次と同等です。

```powershell
tailscale serve --yes --bg --http 3456 http://127.0.0.1:3457
```

EverVigilはFunnelを有効にしません。listenerはTailnet-onlyで、Tailscale identity、
設定されている場合のdevice posture、Tailnet ACL policyに依存します。public Internet
endpointではありません。

経路の適用・置換・削除前にServe statusを読み、root mappingとloopback転送先が
永続化済みcurrent-user所有記録に一致することを確認します。無関係または曖昧な経路を
上書き・削除しません。設定変更に必要な保守操作だけUACを要求し、通常監視は昇格しません。

通知領域EXE、PowerShell script、その他application userが書換可能なfileを昇格実行しません。
medium-integrity clientは`%ProgramData%\EverVigil\Broker`配下のversion固定canonical
`EverVigil.Broker.exe`だけへ接続します。brokerはnamed-pipe clientのprocess handle、SID、
session、integrity level、一回限りのnonceを認証します。high integrityで許可するのは固定の
system構成操作だけで、caller指定programやscriptを実行しません。Tailscaleも保護された固定
install pathからだけ解決します。

権威あるwrite-through `pending-system-configuration.json`、applied台帳、変更前台帳snapshot、
transaction receiptは、非昇格processではなくcanonical brokerが、元user SID別のACL保護済み
ProgramData state directoryへ保存します。journalには変更前後のport、preflight経路所有権、
Firewall rule完全identity、単調なmutation phaseを記録し、各外部変更直前に変更意図を
durable化します。receipt replayにより、応答消失やcommit書込み間のcrashもidempotentに
再開します。LocalAppDataのtransaction dataはinstaller進行を調整しますが、特権resourceの
所有権証拠には使用しません。

このため途中終了後も、完全一致を検証できる完了済み変更だけを確定するか、検証済みの変更前
状態だけを復元できます。Funnel、未知の経路、重複または不一致のFirewall rule、信頼できない
Tailscale executable、journal/client identity不一致はfail closedとし、回復完了までbackendを
停止状態に保ちます。

## 4. QR connection flow（QR接続フロー）

接続値は次のとおりです。

```text
http://<Tailscale-hostname>:3456/?token=<bridge-token>&defaultProvider=codex
```

QR codeは同梱QRCoder libraryによりprocess内で生成します。URLやtokenを外部QR serviceへ
送りません。URL、QR code、tokenはcredentialとして既定非表示にし、明示的な`表示`
操作後だけ表示します。約60秒後、およびwindow非アクティブ時に直ちに隠します。

hostはユーザーが指定できません。read-onlyの保護ブローカー台帳がactive構成に一致し、
台帳のTailscale addressが現在この端末に割り当てられ、記録済みTailscale Self名の全DNS応答が
その保護済みlocal addressであり、現在のServe rootが保護対象public portから保護対象loopback
backendへ正確に対応しFunnelが無効な場合だけRevealとCopyを許可します。machine名や任意hostへ
fallbackしません。

copy時はcredentialがclipboard履歴や他アプリへ残る可能性を警告します。設定時間後に
clipboard内容が変わっていない場合だけ消去します。QR pixel、接続URL、token値を
意図的にログへ書きません。

約60秒は表示寿命であり、tokenの有効期限ではありません。panelを隠す操作やwindow
非アクティブ化はtokenをrotateしません。漏洩が疑われる場合はユーザーが再生成します。

## 5. Network boundaries（ネットワーク境界）

Tailscale Serveは`127.0.0.1:3457`を転送先とし、Codex app-serverは
`127.0.0.1:8765`を使用します。Tailscale Serve port 3456だけをclientの想定入口とします。
アプリ所有・SID識別可能なWindows Firewall ruleにより、Even Terminal backendへの
直接受信を遮断します。撤去時は所有権を検証し、無関係なruleを削除しません。

検証対象の公式`@evenrealities/even-terminal` 0.8.1はlistenerを`0.0.0.0`へbindします。
EverVigilは公式packageをpatchしないため、現時点で厳密なloopback-only bindを保証できません。
所有Firewall ruleは必須の緩和策であり、この上流挙動はRelease riskとして残ります。

security boundaryはWindows user分離、所有Firewall rule、Tailscale device identity、
Tailnet ACL、Codex app-serverのloopback-only accessの組み合わせです。public-Internet listener、Funnel、独自cloud
backend、外部relayを作りません。

## 6. Credential handling（認証情報の取扱い）

暗号学的に安全な乱数生成器で16 bytes以上を生成し、32文字の16進bridge tokenへ
表現します。application-specific entropy付きWindows DPAPI `CurrentUser`で保護し、
制限ACLで保存します。一時fileから置換することでpartial writeを防ぎます。

平文tokenはmanaged bridgeへ`BRIDGE_TOKEN`環境変数だけで渡し、process command lineへ
載せません。接続URLとQR codeも同等のcredentialとして扱います。

launcherとNode bridgeの環境は、固定Windows/profile path、設定済み実行fileの検索directory、
非secretなEverVigil runtime値、`BRIDGE_TOKEN`だけから新規構築します。親processの
`OPENAI_API_KEY`、`GH_TOKEN`、`CODEX_HOME`、`PROJECT_DIR`、proxy設定、継承`PATH`は
渡さず、global `--cwd`も指定しません。環境変数によるCodex認証は意図的に非対応とし、
別管理のCodex CLI認証だけを使用します。

managed bridge稼働中は、そのchild環境内に平文が存在し、same-user process inspectionや
crash dumpから観測される可能性があります。DPAPIが保護するのは保存時tokenであり、
同じユーザーで動くsoftwareやadministratorからlive processを保護しません。

EverVigilはCodex認証情報を読取り、保存、copy、export、送信しません。Codex認証は
ユーザーが別途導入したCodex CLIだけが管理します。

DPAPI `CurrentUser`は同じユーザー権限の悪意あるcodeから守る境界ではありません。
local administratorもsecurity boundaryとして扱いません。

## 7. Logging and redaction（ログと秘匿化）

ログはfile sizeと世代数を制限します。書込み前にURLの`token` query値、Bearer
credential、既知bridge token、32文字の16進token形式値を秘匿化します。QR payloadと
完全な接続URLは診断eventにしません。上流childのstdoutとstderrはprocess停止を防ぐため
排出しますが、起動bannerにcredentialと機械可読QRが含まれるため、EverVigilのログへ
保持・転送しません。

診断ログにはlocal path、hostname、dependency error、application contentが残る可能性が
あります。共有前に利用者が確認・sanitizationしてください。Codex認証dataは収集・記録しません。

## 8. Update mechanism（更新機構）

EverVigilに自動更新機能はありません。GitHub Releasesから
`EverVigil-<version>-Setup.exe`を手動取得し、公開SHA-256と照合して既存導入へ
上書き実行します。コミュニティbinaryは未署名で、Microsoft Defender SmartScreenが
警告する場合があります。

checksumはfileがrepository掲載値と一致することを示します。installerとchecksumを同じ
Releaseから取得する場合、checksumだけではpublisher真正性を独立に証明できないため、
repositoryとReleaseのidentityも確認する必要があります。

変更前に永続transactionを記録し、可変dataをsnapshotし、旧稼働版を保持します。
設定、DPAPI保護済みtoken、自動起動選択を維持します。旧shortcut、support、平文credential、
一時treeなど失敗し得る外部退役処理は、snapshotから旧版へ戻せる間にすべて完了します。
永続`SystemCommitPrepared`境界より前の失敗では、検証済みsnapshot、旧program、system設定、
startup状態、稼働状態を復元します。rollbackを検証できない場合はpartial serviceを開始せず、
起動禁止状態を維持します。

`SystemCommitPrepared`は、新版と外部post-stateをすべて検証した後だけ記録します。この境界後は
応答を失っていても保護brokerがcommit済みの可能性があるため、安全性を推測せずforward recovery
だけを行います。最終証拠の削除が中断した場合、setupは復旧必要codeを返し、検証済み新版を
activeのまま保持して、同じinstallerによる同一transactionの再開を要求します。保護commit後に
残るのはbackupとtransaction証拠の削除だけです。

アプリ本体はユーザーscopeへ導入します。runtime dependencyが不足している
`CONFIGURATION REQUIRED`の導入では昇格を行いません。system構成を適用できる場合は、
初回の保護broker導入とApplyを1回の短時間UAC処理にまとめます。transactionをsealした後の
Commitだけを別の短時間UAC処理として実行し、通常監視を昇格しません。通知領域アプリは
Commit完了後に予約され、Setup processが終了してから起動するため、初回表示時点で保護された
Tailscale identityを読み取れます。

## 9. Upgrade from Even Terminal Supervisor（旧製品からの移行）

EverVigil v2.0.0は旧v1.2.1からin-place upgradeします。既存Inno Setup AppIdを維持する
方式により、Windowsがv2.0.0を置換導入として扱い、同じユーザーの対応する設定と
DPAPI保護済みtokenを維持できます。保持するAppId、entropy互換性、旧path、mutex、task name、
その他の旧identifierは実装の`LegacyCompatibility`境界へ集約し、EverVigilの製品名として表示しません。

停止・移動・削除前に旧導入とresource所有権を検証します。対応する設定、token、自動起動選択を
保持し、ユーザー表示をEverVigilへ変更します。EverVigil正常化後に、所有確認できた旧process、
Startup entry、shortcut、Firewall rule、Serve mapping、transaction data、support file、
install fileだけを撤去します。無関係なresourceは保持し、所有が曖昧ならfail-closedにします。

旧構成変換も有効化と同じ永続transactionに含めます。setup commitまでは旧programと
検証済みsnapshotを保持し、失敗時は旧runtime再起動前に移行前状態を復元します。

v1.2.1状態の復号・同期に必要な間は、検証済み旧data root、DPAPI entropy context、同期名を
継続使用する場合があります。これらは互換内部情報であり、ユーザー向けbrandではありません。
currentと旧data rootの両方に永続状態がある場合、暗黙に一方を選ばず起動をfail-closedにします。

Release承認前に実機v1.2.1-to-v2.0.0 migration testを行い、対応する設定・tokenが使えること、所有する
process、経路、rule、shortcut、自動起動entry、導入directoryが重複しないことを確認します。

## 10. Uninstall process（アンインストール処理）

Windows Installed AppsまたはEverVigilのStart menu shortcutから実行できます。

1. 保留中のinstall recoveryを確認し、transaction lockを取得します。
2. EverVigilと所有する子process treeを停止します。
3. 所有確認済みTailscale Serve経路とFirewall構成だけを削除します。
4. EverVigilの自動起動entryとshortcutを削除します。
5. 検証済み導入directory、transaction journal、一時fileを削除します。
6. ユーザー選択に従い、設定とDPAPI tokenを保持または削除します。

保持を選ぶと、暗号化token、設定、`BridgeHost`をEverVigil data directoryへ意図的に
残します。削除を選んだ場合、空の`BridgeHost`は削除し、非空ならfileを削除せず正確な
保持pathを報告します。所有childを停止するとprocess-localな`BRIDGE_TOKEN`環境も消滅します。
所有system構成の撤去を検証できない場合、complete removalとせずuninstall失敗を報告します。

canonical privileged brokerは、Windows SIDごとにmachine-wide resourceの所有証拠を保持します。
設定・tokenを保持する選択にかかわらず、uninstallはcurrent SIDの保護stateを必ず退役させます。
別SIDの保護済みEverVigil stateが残る場合はshared canonical brokerを維持し、その事実を
uninstall結果へ明記します。最後のSIDでは、brokerがdurable retirement receiptを書き、元userへ
固定canonical fileと空directoryに対するdelete-only権限だけを付与します。昇格broker終了後、
medium-integrity uninstallerがreceipt、image hash、bounded tree、ACL、reparse point不存在を
再検証して固定pathだけをbottom-upで削除します。応答消失・途中停止は保護receiptから再開します。
Windows再起動まで削除を延期する必要がある場合は、正確な残留pathを示してuninstallを停止し、
再起動後の再実行が完了するまでcomplete removalを名乗りません。

hard crashで残るatomic temporaryはfile名だけを根拠に削除しません。settings/applied-state JSONは
bounded schema、token dataは固定application entropyを用いたCurrentUser DPAPI tokenとしての
復号、全fileはcurrent-owner restricted ACLを検証します。pending-system temporaryはprotected
broker transactionとの整合・復旧後だけ削除します。設定・token保持時も検証済みobsolete tempは
撤去し、unknown fileやreparse pointがあればfail-closedでuninstallを停止します。

Tailscale、Node.js、Codex、`@evenrealities/even-terminal`、無関係なServe経路・
Firewall rule、未検証directory、ユーザーが独自作成した設定は削除しません。
所有検査に失敗した場合は破壊的処理前に停止します。

## 11. Security limitations（セキュリティ上の制限）

- コミュニティutilityであり、vendor security productやsecurity auditではありません。
- 検証対象のEven Terminal 0.8.1では、明示済み／保存済みの利用可能なworking directoryが
  ないrequestが非公開の`BridgeHost`へfallbackする場合があります。EverVigilはproviderを
  patchせず、この上流fieldを必須化できません。
- 未署名binaryはWindowsに警告・遮断される可能性があります。
- v2.0.0のbroker bootstrapは未署名です。初回導入にはpublisher認証済みtrust anchorがなく、
  将来broker binaryを置換するには承認済みcode signingまたはOS-trusted installer設計が必要です。
- SHA-256が示すのはfile同一性であり、publisher identityやcode安全性ではありません。
- Tailnet所属だけでは認可にならず、administratorが適切なACLを維持する必要があります。
- network到達制御はbridge-token認証の代替ではなく、same-host softwareはloopback serviceへ
  到達を試みられます。
- DPAPIはsame-user malwareやlocal administratorから保護しません。
- 接続URLまたはQR codeを取得した者はbridge tokenを取得したことになります。
- 検証対象のEven Terminal listenerはloopback-onlyではなく、直接受信の遮断は所有Firewall
  block ruleに依存します。
- clipboard履歴、screen capture、accessibility tool、同一sessionの別processが表示secretを
  観測できる可能性があります。
- 外部dependencyには各製品固有のsecurity、update、availability riskがあります。
- 所有権検証はfail-closedであり、手動修復が必要になる場合があります。

## 12. No affiliation statement（非提携声明）

This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.

Even Terminalへの参照は互換性の事実説明だけであり、EverVigilの製品名の一部では
ありません。認定・認識バッジを表示しません。
