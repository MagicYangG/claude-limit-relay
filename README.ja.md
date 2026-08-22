# claude-preheat

[English](README.md) | [简体中文](README.zh-CN.md) | **日本語** | [한국어](README.ko.md)

Windows で Claude Code CLI を使う Claude サブスクリプションユーザー向けのツールです。5 時間の利用枠ウィンドウは、枠が空いている状態で送られた最初のメッセージにアンカーされます — スケジュールした極小のピングであなたの選んだ時刻にウィンドウをアンカーし、本番の作業を 2 つの 5 時間ウィンドウにまたがらせます。できることは 2 つ:

1. 週単位の定期予熱
2. 単発の予熱

## Web パネル

ローカルアドレス: `localhost:7878`(英語/中国語のバイリンガル、ヘッダーでワンクリック切替)

モジュール: リアルタイム利用枠バー(5 時間 + 週次、正確なリセット時刻付き — `preheat statusline on` を一度実行すると値が流れます)/ 週次リセット時刻エディタ(`schedule.json` に書き込んで適用)/ 単発予熱 / 直近 7 日のウィンドウ利用率ライン(内部は `preheat learn`)

![panel](docs/panel.png)

## クイックスタート

**動作要件**: Windows 10/11、[Claude Code CLI](https://code.claude.com/docs) インストール&ログイン済み、Claude サブスクリプション、PowerShell 7 (pwsh)、管理者権限は不要

**推奨: 以下を Claude Code(または他の AI コーディングツール)に貼り付けて、インストールを任せてください:**

```text
https://github.com/MagicYangG/claude-preheat をクローンしてセットアップして:
1. git clone 後、リポジトリのディレクトリ内で install.ps1 を実行
2. 毎週ウィンドウをリセットしたい時刻を私に聞いて、schedule.json に書き込む
   (reset にはリセット目標時刻を書く。予熱時刻は自動で reset − 5 時間)
3. ./test.ps1 を実行し、全ケースの成功を確認
4. preheat apply を実行し、preheat status の出力を見せて
install.ps1 と preheat apply が作るもの以外、何も登録・変更しないこと。
```

終わったらブラウザで `http://localhost:7878` を開き、あとはパネルから操作できます。

**手動インストールは 3 ステップ**: `git clone` → `./install.ps1` → 新しいターミナルで `preheat apply`。コマンド一覧は[コマンドリファレンス](#コマンドリファレンス)へ。

## 注意事項

1. **Claude Code CLI が必要**: 予熱は CLI 経由で実行される極小のヘッドレスプロンプトです
2. **稼働中のウィンドウへのピングは無害な no-op**: 些細なメッセージ 1 通ぶんのコストだけで、何も動きません
3. **スリープからの復帰**: スケジュールした予熱が PC を起こせるのは、有効な電源プランでスリープ解除タイマーが有効な場合だけです — 無効なときは `preheat status` が警告します

## relay はどこへ行った?

v0.2.0 にはウィンドウ跨ぎの自動再開(「relay」)が入っていました。Claude Code v2.1.234 から CLI が制限リセット時の自動継続を標準搭載した(デフォルトで有効、`/config` の「Continue automatically at usage limit」)ため、v0.3.0 で relay を引退させました。relay 入りの最後のリリースはタグ [v0.2.0](https://github.com/MagicYangG/claude-preheat/releases/tag/v0.2.0) に残してあります。ネイティブ機能がやらないこと — 席に着く前にウィンドウを開始すること — こそが preheat の仕事です。

## コマンドリファレンス

普段使いはパネルで足ります。以下はターミナル派とスクリプト向けです。

```powershell
preheat apply           # schedule.json から毎週の予熱タスクを登録(編集後に再実行で反映)
preheat status          # ローカル活動 + 登録タスク + 直近ログ
preheat reset 20:00     # 単発: ウィンドウを 20:00 にリセットさせる(15:00 に予熱)
preheat at 15:00        # 単発: 15:00 に予熱
preheat +2h             # 単発: 2 時間後に予熱
preheat learn           # 直近 30 日のリズムから予熱時刻を提案 + 窓利用率レポート(learn auto で適用)
preheat statusline on   # statusline を透過タップし、正確なリセット時刻をパネルの利用枠バーへ(off で復元)
preheat off             # 予熱タスクを全削除
claude-panel            # ローカル Web パネルを開く
```

`schedule.json` の `reset` は**リセット目標時刻**。予熱時刻は自動で reset − 5h。`proxy` が空ならプロキシなし。

## アンインストール

```powershell
preheat off             # 予熱タスクを全削除
preheat statusline off  # 元の statusline を復元(タップを有効にしていた場合)
```

その後、PowerShell プロファイルの `# >>> claude-preheat functions >>>` から
`# <<< claude-preheat functions <<<` までの行を削除し(古いインストールでは
`claude-limit-relay` のマーカーになっている場合があります)、リポジトリの
ディレクトリを削除してください。
