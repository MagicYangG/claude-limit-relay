# claude-limit-relay

[English](README.md) | [简体中文](README.zh-CN.md) | **日本語** | [한국어](README.ko.md)

Claude Code CLI を使う Claude サブスクリプションユーザー向けのツールです。できることは 2 つ:

- **利用枠ウィンドウの予熱** — Windows タスクスケジューラで、指定した時刻にウィンドウを先取りします(5 時間ウィンドウは、枠が空いている状態で送られた最初のメッセージにアンカーされます)。本格的に作業を始めるとき、2 つの 5 時間ウィンドウをまたいで使えます
- **ウィンドウ跨ぎのタスク中継** — タスクが 5 時間制限に当たりそう/当たったとき、パネルで登録したタスクが自動で見張り、枠が回復し次第すぐ再開します。戻ってきたらワンクリックで引き継ぎ

## Web パネル

ローカルアドレス: `localhost:7878`(英語/中国語、ヘッダーでワンクリック切替)

3 つのモジュール: 利用枠の予熱 / 中継キュー / 引き継ぎ

![panel](docs/panel.png)

## クイックスタート

**動作要件**: Windows 10/11、[Claude Code CLI](https://code.claude.com/docs) インストール&ログイン済み、Claude サブスクリプション、PowerShell 7 (pwsh)、管理者権限は不要

**推奨: 以下を Claude Code(または他の AI コーディングツール)に貼り付けて、インストールを任せてください:**

```text
https://github.com/MagicYangG/claude-limit-relay をクローンしてセットアップして:
1. git clone 後、リポジトリのディレクトリ内で install.ps1 を実行
2. 毎週ウィンドウをリセットしたい時刻を私に聞いて、schedule.json に書き込む
   (reset にはリセット目標時刻を書く。予熱時刻は自動で reset − 5 時間)
3. ./test.ps1 を実行し、全ケースの成功を確認
4. preheat apply を実行し、preheat status の出力を見せて
install.ps1 と preheat apply が作るもの以外、何も登録・変更しないこと。
```

終わったらブラウザで `http://localhost:7878` を開き、あとはパネルから操作できます。

**手動インストールは 3 ステップ**: `git clone` → `./install.ps1` → 新しいターミナルで `preheat apply`。コマンド一覧は文末の[コマンドリファレンス](#コマンドリファレンス)へ。

## 注意事項

1. **Claude Code CLI が必要**: 予熱も中継も Claude Code CLI 経由で実行されます
2. **再開ウィンドウ**: 再開は同じディレクトリ・同じ会話・同じモデルと effort のまま、別のターミナルウィンドウで走ります。引き継いだら元のウィンドウを閉じ、2 つのウィンドウが同じ会話へ同時に書き込まないようにしてください。再開は `--dangerously-skip-permissions` で走ります(無人ではツール呼び出しを承認できないため)。含意は [SECURITY.md](SECURITY.md) を参照。
3. **モデル別・週次上限のフォールバック**: Claude サブスクリプションにはモデル固有の週次上限があります。タスク登録時に、上限に当たったら opus に切り替えて完走するか、止まって待つかを選べます

## コマンドリファレンス

普段はパネルで十分です。ターミナル派とスクリプト用に:

### 予熱(preheat)

```powershell
preheat apply         # schedule.json から毎週の予熱タスクを登録(編集後に再実行で反映)
preheat status        # ローカル活動 + 登録タスク + 直近ログ
preheat reset 20:00   # 単発: ウィンドウを 20:00 にリセットさせる(15:00 に自動予熱)
preheat at 15:00      # 単発: 15:00 に予熱
preheat +2h           # 単発: 2 時間後に予熱
preheat off           # 予熱タスクを全削除
```

`schedule.json` の `reset` は**リセット目標時刻**。予熱時刻は自動で reset − 5h。`proxy` が空ならプロキシなし。

### 中継(relay)

**2 つのコマンド**: 離席前に `relay arm -Watch`、戻ったら `relay takeover`。

relay は純粋な PowerShell で、どの Claude プロセスにも依存しません。再開が実行するのは `claude --resume <元の会話> -p "<継続プロンプト>"` — 会話の全履歴をマウントし、実際のプロンプトで何を続けるかを伝えます。

| シナリオ | コマンド |
|---|---|
| すでに制限に当たった、席にいる | `relay arm`(候補の会話を確認; `-Yes` でスキップ) |
| これから当たりそう | `relay arm -Watch`(見張り: プローブゼロ、トランスクリプトだけで生死を判定) |
| 戻ってきて引き継ぐ | `relay takeover`(会話バケットに合うディレクトリへ移動 + 元の会話をマウント + 対話 CLI を起動、承認スキップを引き継ぐ。元のウィンドウは閉じること) |

```powershell
relay arm -Prompt "テストを通してから締めて"   # 継続プロンプトを指定
relay status                                  # キュー状態 / プローブタスク / 直近ログ
relay legs a3f8 5                             # 登録を保ったまま中継上限を 5 に変更
relay disarm                                  # 登録解除(進行中の再開プロセスも停止)
```

タスクがまたげるウィンドウ数: 自分で使った 1 つ + デフォルト 3 = 最大 4 ウィンドウ(約 20 時間)。`-MaxLegs N` で調整できます(登録後も `relay legs` かパネルで変更可)。週次上限には注意。

### アンインストール

```powershell
preheat off      # 予熱タスクを全削除
relay disarm     # 登録タスクを全解除
```

その後、`$PROFILE` の `# >>> claude-limit-relay functions >>>` から
`# <<< claude-limit-relay functions <<<` までの行を削除し、リポジトリの
ディレクトリを削除してください。
