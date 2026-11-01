# EverVigil v2.1.0

This is an independent community project. It is not an official Even Realities product and is not developed, operated, maintained, certified, security-reviewed, or supported by Even Realities.

## 変更内容

- CodexとClaudeそれぞれに、新規セッションの開始フォルダ、CLI実行ファイル、モデルを設定できます。
- 開始フォルダは参照ボタンから選択できます。既存セッションは保存済みのフォルダを使います。
- モデルのプルダウンは、稼働中の各CLIが提供する候補を読み込みます。空欄はCLIの既定値を使い、モデルIDや別名の直接入力もできます。
- CLIパスや開始フォルダを変更した場合は「保存 + 再起動」後にモデル候補を開いてください。
- アプリ、保護Broker、Windowsのバージョン情報、インストーラーを2.1.0に統一しました。

## 2.0.0からの更新

1. 旧版のアンインストールで、設定と暗号化tokenの保持を選びます。
2. [v2.1.0のRelease](https://github.com/DaichiMatsumoto/evervigil/releases/tag/v2.1.0)から`EverVigil-2.1.0-Setup.exe`と`SHA256SUMS.txt`を取得し、インストーラーのSHA-256を照合します。
3. 2.1.0をインストールします。異なる版の保護Brokerは併存できず、2.0.0への直接上書きは拒否されます。

自動更新機能はありません。コミュニティビルドはAuthenticode未署名です。
セキュリティ修正の対象は2.1.0です。旧版の利用者は更新してください。

## 配布と設定情報

Even Terminal、Codex、Claude、Node.js、Tailscaleは別途導入する製品です。
EverVigilにはこれらのCLI本体や認証情報を同梱しません。
個別環境のフォルダ、ホスト名、token、接続URLは公開資料へ含めないでください。

利用方法は[日本語ガイド](docs/README.ja.md)、保護境界は[セキュリティ文書](docs/SECURITY.ja.md)を参照してください。
