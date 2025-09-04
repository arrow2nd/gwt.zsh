# gwt.zsh - Git Worktree Manager Plugin
# A zsh plugin for managing git worktrees efficiently

# プラグインの初期化
if [[ -z "$GWT_VERSION" ]]; then
    export GWT_VERSION="1.5.0"
fi

# デフォルト設定
if [[ -z "$GWT_ROOT_DIR" ]]; then
    export GWT_ROOT_DIR="$HOME/.gwt"
fi

# gwt関数の実装
_gwt_internal() {
    # エラー時の処理
    setopt LOCAL_OPTIONS ERR_EXIT

    # 使用方法を表示
    show_usage() {
        cat << EOF
Usage: gwt <command> [branch_name]

Commands:
    add [branch]     Create a new worktree and move to it
    remove [branch]  Remove the specified worktree
    move [branch]    Move to the specified worktree directory
    list             List all worktrees
    pr-checkout <id> Check out a pull request into a new worktree
    prune            Remove worktrees for deleted remote branches
    version          Show version information
    help             Show this help

If branch_name is omitted, fzf will be used for selection.

Configuration:
    GWT_ROOT_DIR     Root directory for storing worktrees (required)

Examples:
    gwt add feature/new-api
    gwt move
    gwt remove old-feature
    gwt pr-checkout 123
    gwt list
EOF
    }

    # エラーメッセージを表示して終了
    error_exit() {
        echo "gwt: $1" >&2
        return 1
    }

    # 必要なコマンドの存在確認
    check_dependencies() {
        if ! command -v git >/dev/null 2>&1; then
            error_exit "git is not installed"
        fi
    }

    # Gitリポジトリかどうかチェック
    check_git_repo() {
        if ! git rev-parse --git-dir >/dev/null 2>&1; then
            error_exit "not in a git repository"
        fi
    }

    # ルートディレクトリの取得
    get_root_dir() {
        local root_dir="$GWT_ROOT_DIR"

        # GWT_ROOT_DIRが設定されていない場合はエラー
        if [[ -z "$root_dir" ]]; then
            error_exit "GWT_ROOT_DIR is not set. Please set it to your desired root directory:
  export GWT_ROOT_DIR=<path>"
        fi

        # チルダを展開
        root_dir="${root_dir/#\~/$HOME}"
        echo "$root_dir"
    }

    # プロジェクト名を取得（ghq風のパス形式）
    get_project_name() {
        local main_worktree remote_url
        
        # メインワークツリーのパスを取得（最初のワークツリーがメイン）
        main_worktree=$(git worktree list --porcelain | awk '/^worktree/ {print $2; exit}')
        
        # メインワークツリーのGitディレクトリから情報を取得
        remote_url=$(git -C "$main_worktree" config --get remote.origin.url 2>/dev/null)

        if [[ -z "$remote_url" ]]; then
            # リモートがない場合はディレクトリ名を使用
            echo "local/$(basename "$main_worktree")"
            return
        fi

        # SSH形式: git@github.com:user/repo.git
        if [[ "$remote_url" =~ ^git@([^:]+):([^/]+)/([^/]+)\.git$ ]]; then
            echo "${match[1]}/${match[2]}/${match[3]}"
        # HTTPS形式: https://github.com/user/repo.git
        elif [[ "$remote_url" =~ ^https?://([^/]+)/([^/]+)/([^/]+)\.git$ ]]; then
            echo "${match[1]}/${match[2]}/${match[3]}"
        # .gitなしのHTTPS形式: https://github.com/user/repo
        elif [[ "$remote_url" =~ ^https?://([^/]+)/([^/]+)/([^/]+)$ ]]; then
            echo "${match[1]}/${match[2]}/${match[3]}"
        else
            # フォールバック：ディレクトリ名を使用
            echo "local/$(basename "$main_worktree")"
        fi
    }

    # worktreeのベースディレクトリを取得
    get_worktree_base() {
        local root_dir project_name
        root_dir=$(get_root_dir)
        project_name=$(get_project_name)

        echo "$root_dir/$project_name"
    }

    # 既存のブランチ一覧を取得（fzf用）
    get_branches_for_fzf() {
        local local_only="$1"

        if [[ "$local_only" == "true" ]]; then
            # ローカルブランチのみ
            git branch -l --format="%(refname:short)" | \
                grep -v '^HEAD' | \
                sort -u
        else
            # 全ブランチ（リモート含む）
            git branch -a --format="%(refname:short)" | \
                grep -v '^HEAD' | \
                sed 's|^origin/||' | \
                sort -u
        fi
    }

    # 既存のworktree一覧を取得（fzf用）
    get_worktrees_for_fzf() {
        git worktree list --porcelain | \
            awk '/^branch/ {gsub(/^refs\/heads\//, "", $2); print $2}' | \
            grep -v '^$'
    }

    # fzfでブランチを選択
    select_branch_with_fzf() {
        local prompt="$1"
        local branches

        if ! command -v fzf >/dev/null 2>&1; then
            error_exit "fzf is required for interactive selection"
            return 1
        fi

        if [[ "$prompt" == "remove" ]]; then
            branches=$(get_worktrees_for_fzf)
        elif [[ "$prompt" == "move" ]]; then
            branches=$(get_branches_for_fzf "true")
        else
            branches=$(get_branches_for_fzf)
        fi

        if [[ -z "$branches" ]]; then
            error_exit "no branches found"
            return 1
        fi

        local selected
        selected=$(echo "$branches" | fzf --prompt="Select branch to $prompt: " --height=40% --border)

        echo "$selected"
    }

    # worktreeを追加
    gwt_add() {
        local branch="$1"
        local base_dir worktree_dir

        if [[ -z "$branch" ]]; then
            branch=$(select_branch_with_fzf "add")
            if [[ -z "$branch" ]]; then
                error_exit "no branch selected"
                return 1
            fi
        fi

        base_dir=$(get_worktree_base)
        worktree_dir="$base_dir/$branch"

        # ディレクトリが既に存在するかチェック
        if [[ -d "$worktree_dir" ]]; then
            error_exit "worktree directory already exists: $worktree_dir"
            return 1
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
    gwt_remove() {
        local branch="$1"
        local base_dir worktree_dir current_dir need_move=false

        if [[ -z "$branch" ]]; then
            branch=$(select_branch_with_fzf "remove")
            if [[ -z "$branch" ]]; then
                error_exit "no branch selected"
                return 1
            fi
        fi

        base_dir=$(get_worktree_base)
        worktree_dir="$base_dir/$branch"

        # worktreeが存在するかチェック
        if ! git worktree list | grep -q "$worktree_dir"; then
            error_exit "worktree not found: $worktree_dir"
            return 1
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
                return 1
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
    gwt_move() {
        local branch="$1"
        local worktree_dir

        if [[ -z "$branch" ]]; then
            branch=$(select_branch_with_fzf "move")
            if [[ -z "$branch" ]]; then
                error_exit "no branch selected"
                return 1
            fi
        fi

        # git worktree listから実際のパスを取得
        worktree_dir=$(git worktree list --porcelain | awk -v branch="$branch" '
            /^worktree/ { path = $2 }
            /^branch/ && $2 == "refs/heads/" branch { print path; exit }
        ')

        # worktreeディレクトリが見つからない場合
        if [[ -z "$worktree_dir" ]]; then
            # worktreeが存在しない場合、ブランチが存在するかチェック
            if git show-ref --verify --quiet "refs/heads/$branch" || git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
                # ブランチが存在する場合はgit switchでブランチ切り替え
                echo "Worktree not found for branch '$branch'. Switching to branch instead..." >&2
                git switch "$branch"
                echo "$(pwd)"
                return 0
            else
                error_exit "branch '$branch' does not exist"
                return 1
            fi
        fi

        # ディレクトリが存在するかチェック
        if [[ ! -d "$worktree_dir" ]]; then
            error_exit "worktree directory not found: $worktree_dir"
            return 1
        fi

        echo "$worktree_dir"
    }

    # worktree一覧を表示
    gwt_list() {
        local base_dir
        base_dir=$(get_worktree_base)

        echo "Git worktrees:"
        git worktree list
        echo
        echo "Base directory: $base_dir"
    }

    # バージョン情報を表示
    gwt_version() {
        echo "gwt version $GWT_VERSION"
        echo "Git Worktree Manager for zsh"
    }

    # PRをチェックアウトしてworktreeを作成
    gwt_pr_checkout() {
        local pr_id="$1"

        # PR IDが指定されていない場合
        if [[ -z "$pr_id" ]]; then
            error_exit "PR ID is required. Usage: gwt pr-checkout <PR_ID>"
            return 1
        fi

        # PR IDが数値かチェック
        if ! [[ "$pr_id" =~ ^[0-9]+$ ]]; then
            error_exit "PR ID must be a number"
            return 1
        fi

        # ghコマンドの存在確認
        if ! command -v gh >/dev/null 2>&1; then
            error_exit "GitHub CLI (gh) is required for pr-checkout command. Please install it from https://cli.github.com"
            return 1
        fi

        # jqコマンドの存在確認
        if ! command -v jq >/dev/null 2>&1; then
            error_exit "jq is required for pr-checkout command. Please install it"
            return 1
        fi

        # PR情報を取得
        echo "Fetching PR #$pr_id information..." >&2
        local pr_info
        pr_info=$(gh pr view "$pr_id" --json number,headRefName,headRepository,headRepositoryOwner 2>&1)

        if [[ $? -ne 0 ]]; then
            error_exit "failed to fetch PR #$pr_id: $pr_info"
            return 1
        fi

        # JSONからブランチ名を取得
        local branch
        branch=$(echo "$pr_info" | jq -r '.headRefName')

        if [[ -z "$branch" ]] || [[ "$branch" == "null" ]]; then
            error_exit "could not determine branch name for PR #$pr_id"
            return 1
        fi

        echo "PR #$pr_id branch: $branch" >&2

        # worktreeのベースディレクトリとパスを構築
        local base_dir worktree_dir
        base_dir=$(get_worktree_base)
        worktree_dir="$base_dir/$branch"

        # ディレクトリが既に存在するかチェック
        if [[ -d "$worktree_dir" ]]; then
            echo "Worktree already exists for branch '$branch', moving to it..." >&2
            echo "$worktree_dir"
            return 0
        fi

        # ベースディレクトリを作成
        mkdir -p "$base_dir"

        # リモートから最新情報をfetch
        echo "Fetching latest changes..." >&2
        git fetch origin

        # worktreeを作成
        echo "Creating worktree for PR #$pr_id (branch: $branch)..." >&2
        git worktree add "$worktree_dir" -b "$branch" "origin/$branch" 2>&1 || {
            # ブランチが存在しない場合は、PRから直接チェックアウト
            echo "Branch not found in origin, checking out from PR..." >&2
            git worktree add "$worktree_dir" -b "$branch"
            cd "$worktree_dir"
            gh pr checkout "$pr_id"
            cd - > /dev/null
        }

        echo "✓ PR #$pr_id checked out to worktree: $worktree_dir" >&2
        echo "$worktree_dir"
    }

    # リモートで削除されたブランチのworktreeを削除
    gwt_prune() {
        # この関数内ではERR_EXITを無効化
        setopt LOCAL_OPTIONS NO_ERR_EXIT

        local base_dir
        base_dir=$(get_worktree_base)

        echo "Fetching remote changes and pruning..." >&2
        git fetch --prune

        # デフォルトブランチを取得
        local default_branch

        # mainまたはmasterを優先的に使用
        if git show-ref --verify --quiet "refs/heads/main"; then
            default_branch="main"
        elif git show-ref --verify --quiet "refs/heads/master"; then
            default_branch="master"
        else
            # フォールバック：リモートのHEADから取得
            default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
            if [[ -z "$default_branch" ]]; then
                error_exit "cannot determine default branch"
                return 1
            fi
        fi


        # マージ済みのブランチを取得
        local merged_branches
        merged_branches=$(git branch --merged "$default_branch" 2>&1 | grep -v "^\*" | sed 's/^[+[:space:]]*//')

        # 削除されたリモートブランチを取得
        local deleted_branches=()
        local worktree_branches
        worktree_branches=$(git worktree list --porcelain | awk '/^branch/ {gsub(/^refs\/heads\//, "", $2); print $2}' | grep -v '^$')

        # 各worktreeブランチをチェック
        local removed_count=0
        while IFS= read -r branch; do
            # mainやmasterは除外
            if [[ "$branch" == "main" ]] || [[ "$branch" == "master" ]] || [[ "$branch" == "$default_branch" ]]; then
                continue
            fi

            local should_remove=false
            local reason=""

            # 1. ブランチがマージ済みかチェック
            if echo "$merged_branches" | grep -q "^${branch}$"; then
                should_remove=true
                reason="merged into $default_branch"
            # 2. リモートブランチが存在しない場合
            elif ! git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
                # 追跡ブランチを持っていたかチェック
                local tracking_branch
                tracking_branch=$(git for-each-ref --format='%(upstream:short)' "refs/heads/$branch" 2>/dev/null)

                if [[ -n "$tracking_branch" ]]; then
                    should_remove=true
                    reason="remote branch deleted"
                fi
            fi

            if [[ "$should_remove" == true ]]; then
                echo "Found orphaned worktree: $branch ($reason)" >&2
                deleted_branches+=("$branch")
            fi
        done <<< "$worktree_branches"

        # 削除確認
        if [[ ${#deleted_branches[@]} -eq 0 ]]; then
            echo "✓ No orphaned worktrees found" >&2
            return 0
        fi

        echo "" >&2
        echo "The following worktrees will be removed:" >&2
        for branch in "${deleted_branches[@]}"; do
            echo "  - $branch" >&2
        done
        echo "" >&2

        # 確認プロンプト
        echo -n "Proceed with removal? [y/N] " >&2
        local response
        read -r response

        if [[ "$response" != "y" ]] && [[ "$response" != "Y" ]]; then
            echo "Cancelled" >&2
            return 0
        fi

        # worktreeを削除
        for branch in "${deleted_branches[@]}"; do
            local worktree_dir="$base_dir/$branch"
            if [[ -d "$worktree_dir" ]]; then
                echo "Removing worktree: $branch" >&2
                # git worktree removeを実行（エラーを無視）
                if git worktree remove "$worktree_dir" 2>&1; then
                    ((removed_count++))
                else
                    echo "Failed to remove worktree: $branch" >&2
                fi
            fi
        done

        echo "" >&2
        echo "✓ Removed $removed_count worktree(s)" >&2
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
        pr-checkout)
            gwt_pr_checkout "$branch"
            ;;
        prune)
            gwt_prune
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
            return 1
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
                'pr-checkout:Check out a pull request into a new worktree'
                'prune:Remove worktrees for deleted remote branches'
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
                add|move|mv|cd)
                    # 全ブランチ（リモート含む）
                    local branches=($(git branch -a --format="%(refname:short)" 2>/dev/null | grep -v '^HEAD' | sed 's|^origin/||' | sort -u))
                    _describe 'branches' branches
                    ;;
                remove|rm)
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
        add|move|mv|cd|remove|rm|pr-checkout)
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
