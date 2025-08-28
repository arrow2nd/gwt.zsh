# gwt.zsh test

🌳 効率的にGit Worktreeを管理するためのzshプラグイン

## 概要

gwtは、Git Worktreeの作成・削除・移動を簡単に行えるzshプラグインです。fzfを使った対話的な操作をサポートしています。

## インストール

### zinit

```zsh
zinit light arrow2nd/gwt.zsh
```

### oh-my-zsh

```bash
git clone https://github.com/arrow2nd/gwt.zsh $ZSH_CUSTOM/plugins/gwt.zsh
```

`.zshrc`に追加:

```zsh
plugins=(... gwt.zsh)
```

## 使い方

```bash
gwt <command> [branch_name]
```

### コマンド

- `add [branch]` - 新しいworktreeを作成
- `remove [branch]` - worktreeを削除
- `move [branch]` - worktreeディレクトリへ移動
- `list` - 全worktreeを一覧表示
- `prune` - リモートで削除されたブランチのworktreeを削除
- `version` - バージョン情報を表示
- `help` - ヘルプを表示

ブランチ名を省略するとfzfで選択できます。

## 設定

### 環境変数

- `GWT_ROOT_DIR` - worktreeを格納するルートディレクトリ（必須、デフォルト: `$HOME/.gwt`）

### ディレクトリ構造

worktreeは以下の構造で作成されます:

```
$GWT_ROOT_DIR/<service>/<user>/<repo>/<branch_name>/
```

例:
```
$GWT_ROOT_DIR/github.com/arrow2nd/gwt.zsh/feature-branch/
```

## 必要な環境

- git
- zsh
- fzf
