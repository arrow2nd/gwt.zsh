# gwt.zsh - Git Worktree Manager Plugin
# A zsh plugin for managing git worktrees efficiently

# プラグインの初期化
if [[ -z "$GWT_VERSION" ]]; then
    export GWT_VERSION="1.0.1"
fi

# デフォルト設定
if [[ -z "$GWT_DEFAULT_ROOT" ]]; then
    export GWT_DEFAULT_ROOT="$HOME/src"
fi

# gwt関数の実装
_gwt_internal() {
    # エラー時の処理
    setopt LOCAL_OPTIONS ERR_EXIT

    # 使用方法を表示
    local show_usage() {
        cat << EOF
Usage: gwt <command> [branch_name]

Commands:
    add [branch]     Create a new worktree and move to it
    remove [branch]  Remove the specified worktree
    move [branch]    Move to the specified worktree directory
    list             List all worktrees
    version          Show version information
    help             Show this help

If branch_name is omitted, fzf will be used for selection.

Configuration:
    GWT_ROOT_DIR     Override root directory (fallback: ghq.root config)
    GWT_DEFAULT_ROOT Default root if neither GWT_ROOT_DIR nor ghq.root is set

Examples:
    gwt add feature/new-api
    gwt move
    gwt remove old-feature
    gwt list
EOF
    }

    # エラーメッセージを表示して終了
    local error_exit() {
        echo "gwt: $1" >&2
        return 1
    }

    # 必要なコマンドの存在確認
    local check_dependencies() {
        if ! command -v git >/dev/null 2>&1; then
            error_exit "git is not installed"
        fi
    }

    # Gitリポジトリかどうかチェック
    local check_git_repo() {
        if ! git rev-parse --git-dir >/dev/null 2>&1; then
            error_exit "not in a git repository"
        fi
    }

    # ルートディレクトリの取得
    local get_root_dir() {
        local root_dir

        # 1. GWT_ROOT_DIR環境変数をチェック
        if [[ -n "$GWT_ROOT_DIR" ]]; then
            root_dir="$GWT_ROOT_DIR"
        # 2. ghq.rootの設定をチェック
        elif root_dir=$(git config --global ghq.root 2>/dev/null) && [[ -n "$root_dir" ]]; then
            : # 何もしない（root_dirは既に設定済み）
        # 3. デフォルト値を使用
        elif [[ -n "$GWT_DEFAULT_ROOT" ]]; then
            root_dir="$GWT_DEFAULT_ROOT"
            echo "gwt: using default root directory: $root_dir" >&2
        else
            error_exit "no root directory configured. Set one of:
  export GWT_ROOT_DIR=<path>
  git config --global ghq.root <path>
  export GWT_DEFAULT_ROOT=<path>"
        fi

        # チルダを展開
        root_dir="${root_dir/#\~/$HOME}"
        echo "$root_dir"
    }

    # プロジェクト名を取得
    local get_project_name() {
        local remote_url
        remote_url=$(git config --get remote.origin.url 2>/dev/null)

        if [[ -z "$remote_url" ]]; then
            # リモートがない場合はディレクトリ名を使用
            basename "$(git rev-parse --show-toplevel)"
            return
        fi

        # GitHubやGitLabのURL形式から名前を抽出
        if [[ "$remote_url" =~ '.*[:/]([^/]+)/([^/]+)\.git$' ]]; then
            echo "${match[2]}"
        elif [[ "$remote_url" =~ '.*[:/]([^/]+)/([^/]+)$' ]]; then
            echo "${match[2]}"
        else
            # フォールバック：ディレクトリ名を使用
            basename "$(git rev-parse --show-toplevel)"
        fi
    }

    # worktreeのベースディレクトリを取得
    local get_worktree_base() {
        local root_dir project_name
        root_dir=$(get_root_dir)
        project_name=$(get_project_name)

        echo "$root_dir/.gwt/$project_name"
    }

    # 既存のブランチ一覧を取得（fzf用）
    local get_branches_for_fzf() {
        git branch -a --format="%(refname:short)" | \
            grep -v '^HEAD' | \
            sed 's|^origin/||' | \
            sort -u
    }

    # 既存のworktree一覧を取得（fzf用）
    local get_worktrees_for_fzf() {
        git worktree list --porcelain | \
            awk '/^branch/ {gsub(/^refs\/heads\//, "", $2); print $2}' | \
            grep -v '^$'
    }

    # fzfでブランチを選択
    local select_branch_with_fzf() {
        local prompt="$1"
        local branches

        if ! command -v fzf >/dev/null 2>&1; then
            error_exit "fzf is required for interactive selection"
        fi

        if [[ "$prompt" == "remove" || "$prompt" == "move" ]]; then
            branches=$(get_worktrees_for_fzf)
        else
            branches=$(get_branches_for_fzf)
        fi

        if [[ -z "$branches" ]]; then
            error_exit "no branches found"
        fi

        echo "$branches" | fzf --prompt="Select branch to $prompt: " --height=40% --border
    }

    # worktreeを追加
    local gwt_add() {
        local branch="$1"
        local base_dir worktree_dir

        if [[ -z "$branch" ]]; then
            branch=$(select_branch_with_fzf "add")
            [[ -z "$branch" ]] && error_exit "no branch selected"
        fi

        base_dir=$(get_worktree_base)
        worktree_dir="$base_dir/$branch"

        # ディレクトリが既に存在するかチェック
        if [[ -d "$worktree_dir" ]]; then
            error_exit "worktree directory already exists: $worktree_dir"
        fi

        # ベースディレクトリを作成
        mkdir -p "$base_dir"

        # worktreeを作成
        echo "Creating worktree for branch '$branch'..." >&2
        if git show-ref --verify --quiet "refs/heads/$branch"; then
            # ローカルブランチが存在する場合
            git worktree add "$worktree_dir" "$branch"
        elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            # リモートブランチが存在する場合
            git worktree add "$worktree_dir" -b "$branch" "origin/$branch"
        else
            # 新しいブランチを作成
            git worktree add "$worktree_dir" -b "$branch"
        fi

        echo "✓ Worktree created: $worktree_dir" >&2
        echo "$worktree_dir"
    }

    # worktreeを削除
    local gwt_remove() {
        local branch="$1"
        local base_dir worktree_dir current_dir need_move=false

        if [[ -z "$branch" ]]; then
            branch=$(select_branch_with_fzf "remove")
            [[ -z "$branch" ]] && error_exit "no branch selected"
        fi

        base_dir=$(get_worktree_base)
        worktree_dir="$base_dir/$branch"

        # worktreeが存在するかチェック
        if ! git worktree list | grep -q "$worktree_dir"; then
            error_exit "worktree not found: $worktree_dir"
        fi

        # 現在のディレクトリを取得
        current_dir="$(pwd)"

        # 削除対象のworktreeにいる場合
        if [[ "$current_dir" == "$worktree_dir" ]]; then
            need_move=true
            # デフォルトブランチ（main または master）のパスを取得
            local default_branch_dir
            default_branch_dir=$(git worktree list --porcelain | awk '
                /^worktree/ { path = $2 }
                /^branch/ && ($2 == "refs/heads/main" || $2 == "refs/heads/master") { print path; exit }
            ')

            if [[ -n "$default_branch_dir" ]] && [[ -d "$default_branch_dir" ]]; then
                echo "Moving to default branch before removing current worktree..." >&2
                echo "$default_branch_dir"
            else
                error_exit "cannot remove current worktree: no default branch found to switch to"
            fi
        fi

        echo "Removing worktree for branch '$branch'..." >&2
        git worktree remove "$worktree_dir"
        echo "✓ Worktree removed: $worktree_dir" >&2

        # need_moveがtrueの場合、呼び出し元でディレクトリ移動を行うためパスを返す
        if [[ "$need_move" == true ]]; then
            echo "$default_branch_dir"
        fi
    }

    # worktreeディレクトリに移動
    local gwt_move() {
        local branch="$1"
        local worktree_dir

        if [[ -z "$branch" ]]; then
            branch=$(select_branch_with_fzf "move")
            [[ -z "$branch" ]] && error_exit "no branch selected"
        fi

        # git worktree listから実際のパスを取得
        worktree_dir=$(git worktree list --porcelain | awk -v branch="$branch" '
            /^worktree/ { path = $2 }
            /^branch/ && $2 == "refs/heads/" branch { print path; exit }
        ')

        # worktreeディレクトリが見つからない場合
        if [[ -z "$worktree_dir" ]]; then
            error_exit "worktree not found for branch: $branch"
        fi

        # ディレクトリが存在するかチェック
        if [[ ! -d "$worktree_dir" ]]; then
            error_exit "worktree directory not found: $worktree_dir"
        fi

        echo "$worktree_dir"
    }

    # worktree一覧を表示
    local gwt_list() {
        local base_dir
        base_dir=$(get_worktree_base)

        echo "Git worktrees:"
        git worktree list
        echo
        echo "Base directory: $base_dir"
    }

    # バージョン情報を表示
    local gwt_version() {
        echo "gwt version $GWT_VERSION"
        echo "Git Worktree Manager for zsh"
    }

    # メイン処理
    check_dependencies
    check_git_repo

    local command="$1"
    local branch="$2"

    case "$command" in
        add)
            gwt_add "$branch"
            ;;
        remove|rm)
            gwt_remove "$branch"
            ;;
        move|mv|cd)
            gwt_move "$branch"
            ;;
        list|ls)
            gwt_list
            ;;
        version|--version|-v)
            gwt_version
            ;;
        help|--help|-h)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            error_exit "unknown command: $command. Use 'gwt help' for usage."
            ;;
    esac
}

# zsh補完関数
_gwt() {
    local context state line
    typeset -A opt_args

    _arguments \
        '1:command:->commands' \
        '2:branch:->branches' \
        && return 0

    case $state in
        commands)
            local commands=(
                'add:Create a new worktree'
                'remove:Remove a worktree'
                'move:Move to worktree directory'
                'list:List all worktrees'
                'version:Show version information'
                'help:Show help'
            )
            _describe 'commands' commands
            ;;
        branches)
            # Gitリポジトリでない場合は補完しない
            if ! git rev-parse --git-dir >/dev/null 2>&1; then
                return 1
            fi

            case $line[1] in
                add)
                    # 全ブランチ（リモート含む）
                    local branches=($(git branch -a --format="%(refname:short)" 2>/dev/null | grep -v '^HEAD' | sed 's|^origin/||' | sort -u))
                    _describe 'branches' branches
                    ;;
                remove|rm|move|mv|cd)
                    # 既存のworktreeのブランチのみ
                    local worktree_branches=($(git worktree list --porcelain 2>/dev/null | awk '/^branch/ {gsub(/^refs\/heads\//, "", $2); print $2}' | grep -v '^$'))
                    _describe 'worktree branches' worktree_branches
                    ;;
            esac
            ;;
    esac
}

# gwt関数のラッパー
gwt() {
    local result
    result=$(_gwt_internal "$@")
    local exit_code=$?

    # エラーが発生した場合はそのまま終了
    if [[ $exit_code -ne 0 ]]; then
        return $exit_code
    fi

    # コマンドに応じて処理を分岐
    case "$1" in
        add|move|mv|cd|remove|rm)
            # パスが返された場合はディレクトリを移動
            # 結果の最後の行（パス）を取得
            local path="${result##*$'\n'}"
            if [[ -n "$path" ]] && [[ -d "$path" ]]; then
                echo "Moving to worktree: $path" >&2
                builtin cd "$path"
            else
                echo "$result"
            fi
            ;;
        *)
            # その他のコマンドは結果をそのまま表示
            [[ -n "$result" ]] && echo "$result"
            ;;
    esac
}

# 補完関数を登録
compdef _gwt gwt


# プラグイン読み込み完了メッセージ（デバッグ用、本番では無効化）
if [[ -n "$GWT_DEBUG" ]]; then
    echo "gwt plugin loaded (version $GWT_VERSION)"
fi
