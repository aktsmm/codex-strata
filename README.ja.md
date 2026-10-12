# codex-strata

Strata のローカルモデルで Codex CLI を使うための、Windows 向けランチャーです。

[English](README.md)

![Codex CLI の実行結果](docs/images/codex-cli.jpg)

このランチャーを使った実際の CLI 実行結果の抜粋を、読みやすく表示して撮影したものです。
個人パスとセッション識別子は省略しています。対話型ターミナルの画面を撮影したものではありません。

```powershell
codex-strata
```

サーバーが動いていれば再利用し、停止していればバックグラウンドで起動します。
HTTP API の応答を確認してから、現在の作業フォルダーで Codex を開きます。
同時に実行してもサーバーは一つだけ起動します。

独立した非公式プロジェクトです。Codex・Strata 本体、モデル、認証情報は含みません。

## 必要なもの

- Windows と PowerShell 7.3 以上。`pwsh` が PATH に通っていること。
- 別途インストールした [Codex CLI](https://github.com/openai/codex)。
- Python 仮想環境とモデル設定を含め、セットアップ済みの [Strata](https://github.com/Niko1221/Strata)。
- Strata のモデルを実行できる PC とモデルファイル。

PowerShell 7.6.6、Codex CLI 0.160.0-alpha.6 で動作確認しています。
ほかのバージョンは未検証です。特に Codex のモデル情報の形式が変わると調整が必要になる可能性があります。

## インストール

このプロジェクトをダウンロードし、そのフォルダーで PowerShell 7 から実行します。

```powershell
.\install.ps1 -StrataRoot "$HOME\dev\Strata" -AddToPath
```

配置先は `%LOCALAPPDATA%\Programs\codex-strata` です。
`-AddToPath` を指定した場合だけユーザーの PATH に追加します。
新しいターミナルを開き、コマンドの場所を確認して起動します。

```powershell
Get-Command codex-strata -All
codex-strata
```

別のモデルの設定ファイルを使う場合は、次のように指定します。

```powershell
.\install.ps1 -StrataRoot 'D:\Strata' -EngineConfig 'strata-coder-iq1_m.json' -AddToPath
```

既存の `codex-strata` が PATH の先にある場合、そのコマンドが優先されます。
インストーラーは競合を表示します。既存コマンドは置き換えないので、配置した `.cmd` をフルパスで実行するか、古いコマンドを整理してください。

更新時は `-Force` を追加します。既存の設定は保持し、置き換えるファイルは `backups` に退避します。
Strata の場所が変わった場合は、保持された `settings.json` を編集してください。
依存関係のインストールやモデルのダウンロードは行いません。
PowerShell の実行ポリシーも変更・回避しません。

## インストールせずに使う

`settings.example.json` を `settings.json` にコピーし、`strata_root` を自分の環境に合わせて編集します。

```powershell
.\codex-strata.cmd
.\codex-strata.cmd exec --skip-git-repo-check 'このフォルダーを変更せずに説明してください。'
```

Codex の引数と終了コードは引き継ぎます。引用符を含む複雑な引数は `.ps1` を直接実行してください。

```powershell
& .\codex-strata.ps1 exec '関数 "parse_input" を説明してください。'
```

`%`、`&`、`|` などを文字として渡す場合も `.ps1` を使ってください。
`.cmd` に到達する前に、呼び出し元のシェルがこれらを解釈する場合があります。
通常の npm 版 `codex.cmd` は自動検出し、Node の実行ファイルを直接呼び出します。
独自のバッチランチャーは受け付けません。

単独の `--help` / `-h` / `--version` / `-V` ではサーバーを起動しません。

## 設定とログ

モデル名・ポート・コンテキスト長は、空欄または `null` の場合に Strata の設定から読み取ります。
起動待ち時間の初期値は 180 秒、応答ストリームの無通信待ち時間は 600 秒です。
設定項目の一覧は [英語版 README](README.md#settings) にあります。

| 設定項目 | 初期値・意味 |
| --- | --- |
| `strata_root` | 必須。Strata の場所。相対パスは設定ファイル基準 |
| `engine_config` | `strata-iq2_xs.json`。相対パスは Strata の場所基準 |
| `model` | 空欄なら設定の `model_name`。指定時はリクエスト用のモデル別名 |
| `port` | `null` なら Strata の設定値。未指定時は 8080 |
| `context_window` | `null` ならエンジン引数の `--max-context`。未指定時は 32768 |
| `reasoning_effort` | `medium`。`none` / `low` / `high` も指定可能 |
| `startup_timeout_seconds` | 180。1～600 秒。HTTP API の起動待ち時間 |
| `stream_idle_timeout_ms` | 600000。応答ストリームの無通信待ち時間 |
| `codex_command` | `codex`。実行ファイル、または通常の npm `codex.cmd` |
| `codex_args_prefix` | `[]`。Codex のオプションより前に渡す文字列の配列 |
| `python_path` | `.venv\Scripts\python.exe`。相対パスは Strata の場所基準 |
| `codex_home` | 空欄なら `%LOCALAPPDATA%\codex-strata\codex-home` |
| `logs_dir` | 空欄なら `%LOCALAPPDATA%\codex-strata\logs` |
| `api_key_env` | 空欄なら認証設定なし。指定する場合はキーを持つ環境変数名 |

独自の配置では、`codex_command` に `node.exe`、`codex_args_prefix` に `codex.js` のパスを指定できます。
サーバーのモデル確認には、別名を指定した場合も Strata 設定の `model_name` を使います。

設定内のパスでは `%USERPROFILE%` などの Windows 環境変数を使えます。
JSON 内の `~` と `$HOME` は展開しません。
`CODEX_STRATA_CONFIG` で設定ファイルの場所を変更できます。

通常の Codex とは別の `CODEX_HOME` を使い、既存の設定や認証情報をコピーしません。
初期値は `%LOCALAPPDATA%\codex-strata\codex-home`、起動ログは `%LOCALAPPDATA%\codex-strata\logs` です。
サーバーは `127.0.0.1` で起動します。

![Strata の Web 画面](docs/images/strata-web.jpg)

実際のローカルサーバーの Web 画面です。会話履歴が写らない空のチャット画面を使っています。

API キーが必要な Strata では、`api_key_env` にキーを持つ環境変数の名前を設定します。
たとえば `STRATA_API_KEY` を使えます。設定にはキー自体を書かず、環境変数に同じキーを用意してください。

`lazy_load` が有効なら、`loaded: false` でも API は起動済みです。
最初の生成リクエストでモデルを読み込みます。アイドル時のモデル解放設定もそのまま使います。
Codex を閉じてもサーバーは継続します。

起動に失敗するとログの場所を表示します。タイムアウト時も起動中のサーバーは停止しないので、ログを確認してから再実行してください。
別アプリがポートを使っている場合や、別モデルが動いている場合はエラーで停止します。
起動ログは自動削除しません。

| 状況 | 確認すること |
| --- | --- |
| 設定が見つからない | インストーラーを実行するか、設定例から `settings.json` を作る |
| Codex が見つからない | `Get-Command codex -All` と `codex_command` を確認 |
| 独自のバッチランチャーが拒否される | 実行ファイルを指定するか、Node と `codex_args_prefix` を使う |
| ポート使用中・別モデル | 使用中のプロセスと設定を確認。既存サーバーは自動停止しない |
| 起動失敗・タイムアウト | 表示された起動ログを確認。起動中なら応答を待ってから再実行 |
| 初回応答が遅い | モデルの読み込みを待つ。RAM・VRAM と Strata のエンジンログを確認 |
| API キーが必要 | `api_key_env` と、同じキーを持つ環境変数を設定 |

## テスト

```powershell
python -B tests/test_launcher.py
```

Python 3.10 以上の標準ライブラリーだけで動きます。
一時的な模擬サーバーを使い、モデルの読み込みや実際の Strata サーバーへの接続は行いません。

推論はローカルですが、Codex 自体のプラグイン更新などが外部サービスに接続する場合があります。
CLI 全体が完全にオフラインになるわけではありません。

公開前のレビュー記録は [docs/REVIEW.md](docs/REVIEW.md) にあります。

## ライセンス

このランチャーは [Apache-2.0](LICENSE)、著作権者は 2026 aktsmm です。
著作権表示は [NOTICE](NOTICE) にも記載しています。
[Strata は MIT](https://github.com/Niko1221/Strata/blob/main/LICENSE)、[Codex CLI は Apache-2.0](https://github.com/openai/codex/blob/main/LICENSE) です。
本体やモデルは同梱せず、それぞれのライセンスが適用されます。
Strata の画面の出典は [NOTICE](NOTICE)、元のライセンスは [docs/licenses/Strata-MIT.txt](docs/licenses/Strata-MIT.txt) に記載しています。
