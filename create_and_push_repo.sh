#!/usr/bin/env bash

set -euo pipefail

# --- FUNÇÃO 'main' MODIFICADA ---
# A lógica foi alterada para SEMPRE tentar um 'pull' (com rebase)
# antes de executar a lógica de 'push'.
main() {
  ensure_dependencies
  ensure_token

  local repo_dir repo_name script_rel remote_url response_file http_status current_branch action
  repo_dir=$(pwd)
  repo_name=$(basename "$repo_dir")
  script_rel=$(script_relative_path "$repo_dir")
  action=$(prompt_push_or_pull "$repo_name")

  init_git_repo
  local repo_had_commits="false"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    repo_had_commits="true"
  fi
  current_branch=$(ensure_main_branch)

  remote_url=$(resolve_remote_url "$repo_name")

  # Se a ação for PUSH, primeiro criamos o repo no GitHub (se necessário)
  if [[ "$action" == "push" ]]; then
    response_file=$(mktemp)
    http_status=$(create_github_repo "$repo_name" "$response_file")
    handle_create_repo_response "$http_status" "$response_file" "$repo_name"
    rm -f "$response_file"
  fi

  # Garantimos que o remoto 'origin' esteja configurado
  ensure_remote "$remote_url"

  # *** LÓGICA CORRIGIDA ***
  # Verificamos se o branch remoto existe antes de tentar o pull.
  # Isso previne erros no primeiro push para um repo novo.
  if git ls-remote --exit-code --heads "$remote_url" "$current_branch" >/dev/null 2>&1; then
    echo "Branch remoto '$current_branch' encontrado. Sincronizando (pull --rebase)..." >&2
    # Sempre puxe (com rebase) antes de qualquer outra ação.
    # Isso previne erros de non-fast-forward.
    pull_with_credentials "$current_branch" # Esta função agora usará --rebase
    echo "Sincronização concluída." >&2
  else
    echo "Branch remoto '$current_branch' não encontrado. Presumindo primeiro push/pull." >&2
  fi
  
  # Atualiza o status de commits após o pull (caso tenha sido o primeiro)
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    repo_had_commits="true"
  fi

  if [[ "$action" == "push" ]]; then
    stage_files_excluding_script "$script_rel"
    if commit_changes "$repo_had_commits"; then
      repo_had_commits="true"
    else
      echo "Nenhuma alteração nova para commitar. Prosseguindo com push (se houver algo do rebase)." >&2
    fi

    push_with_credentials "$current_branch"
    echo "Push concluído com sucesso: $remote_url"
  
  elif [[ "$action" == "pull" ]]; then
    echo "Pull concluído com sucesso de: $remote_url"
    # A ação de pull principal já foi feita acima.
  fi
}

ensure_dependencies() {
  for dep in git curl; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      echo "Erro: dependência '$dep' não encontrada no PATH." >&2
      exit 1
    fi
  done
}

ensure_token() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    return
  fi

  local token_file
  for token_file in GITHUB_TOKEN GITHUB_TOKEN.txt; do
    if [[ -f "$token_file" ]]; then
      if load_token_from_file "$token_file"; then
        break
      fi
    fi
  done

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "Erro: defina a variável de ambiente GITHUB_TOKEN ou crie um arquivo GITHUB_TOKEN(.txt) com um Personal Access Token válido." >&2
    exit 1
  fi
}

load_token_from_file() {
  local token_file=$1 token

  token=$(python3 - "$token_file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    text = path.read_text(encoding="utf-8")
except Exception:
    sys.exit(1)

line = text.splitlines()[0] if text else ""
print(line.lstrip("\ufeff"), end="")
PY
) || return 1

  if [[ -n "$token" ]]; then
    GITHUB_TOKEN=$token
    export GITHUB_TOKEN
    return 0
  fi

  return 1
}

script_relative_path() {
  local repo_dir=$1
  local script_path

  if command -v realpath >/dev/null 2>&1; then
    script_path=$(realpath "$0")
    realpath --relative-to="$repo_dir" "$script_path" || basename "$script_path"
  else
    # Fallback aproximado caso realpath não esteja disponível
    python3 - "$repo_dir" "$0" <<'PY'
import os, sys
repo_dir, script_path = map(os.path.abspath, sys.argv[1:])
try:
    rel = os.path.relpath(script_path, repo_dir)
except ValueError:
    rel = os.path.basename(script_path)
print(rel)
PY
  fi
}

prompt_push_or_pull() {
  local repo_name=$1 choice

  while true; do
    if ! read -rp "Deseja fazer push ou pull para o repositório '$repo_name'? [push/pull] (padrão: push): " choice; then
      choice=""
    fi

    choice=${choice,,}
    case "$choice" in
      ""|push)
        echo "push"
        return
        ;;
      pull)
        echo "pull"
        return
        ;;
      *)
        echo "Entrada inválida. Digite 'push' ou 'pull'." >&2
        ;;
    esac
  done
}

init_git_repo() {
  if [[ ! -d .git ]]; then
    git init
  fi
}

ensure_main_branch() {
  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || true)

  if [[ -z "$current_branch" ]]; then
    # Repositório recém-inicializado sem commits
    git symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || git branch -M main
    current_branch="main"
  elif [[ "$current_branch" != "main" ]]; then
    git branch -M "$current_branch" main
    current_branch="main"
  fi

  echo "$current_branch"
}

remote_exists() {
  local remote_name=$1
  git remote get-url "$remote_name" >/dev/null 2>&1
}

ensure_remote() {
  local expected_url=$1
  if remote_exists "origin"; then
    local current_url
    current_url=$(git remote get-url origin)
    if [[ "$current_url" != "$expected_url" ]]; then
      echo "Erro: remoto 'origin' já configurado para '$current_url'. Ajuste o remoto manualmente para prosseguir." >&2
      exit 1
    fi
  else
    git remote add origin "$expected_url"
  fi
}

create_github_repo() {
  local repo_name=$1
  local response_file=$2
  local api_url="https://api.github.com/user/repos"

  curl -sS \
    -o "$response_file" \
    -w "%{http_code}" \
    -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"name\":\"$repo_name\",\"private\":false}" \
    "$api_url"
}

handle_create_repo_response() {
  local http_status=$1
  local response_file=$2
  local repo_name=$3

  case "$http_status" in
    201)
      return
      ;;
    422)
      echo "Aviso: o repositório '$repo_name' já existe em luascfl. Prosseguindo com o remoto existente." >&2
      ;;
    *)
      echo "Erro ao criar repositório no GitHub (status $http_status):" >&2
      cat "$response_file" >&2
      exit 1
      ;;
  esac
}

resolve_remote_url() {
  local repo_name=$1
  local protocol=${GITHUB_REMOTE_PROTOCOL:-https}

  case "$protocol" in
    ssh)
      echo "git@github.com:luascfl/$repo_name.git"
      ;;
    https)
      echo "https://github.com/luascfl/$repo_name.git"
      ;;
    *)
      echo "Erro: protocolo $protocol não suportado. Use 'https' ou 'ssh'." >&2
      exit 1
      ;;
  esac
}

stage_files_excluding_script() {
  local script_rel=$1

  ensure_token_gitignore
  git add --all
  protect_path "$script_rel"
  protect_path "GITHUB_TOKEN"
  protect_path "GITHUB_TOKEN.txt"
}

ensure_token_gitignore() {
  local gitignore=".gitignore"
  local entries=("GITHUB_TOKEN" "GITHUB_TOKEN.txt" "*API*")
  local appended=0

  if [[ ! -f "$gitignore" ]]; then
    printf "%s\n" "${entries[@]}" >"$gitignore"
    return
  fi

  for entry in "${entries[@]}"; do
    if ! grep -Fxq "$entry" "$gitignore"; then
      if [[ $appended -eq 0 ]]; then
        # Garante quebra de linha antes do primeiro append, se necessário.
        if [[ -s "$gitignore" ]] && [[ $(tail -c1 "$gitignore" 2>/dev/null || printf '') != $'\n' ]]; then
          printf "\n" >>"$gitignore"
        fi
        appended=1
      fi
      printf "%s\n" "$entry" >>"$gitignore"
    fi
  done
}

protect_path() {
  local path=$1
  if [[ -z "$path" ]]; then
    return
  fi

  unstage_if_needed "$path"
  remove_from_index "$path"
}

unstage_if_needed() {
  local path=$1
  git restore --staged "$path" 2>/dev/null || git reset HEAD "$path" 2>/dev/null || true
}

remove_from_index() {
  local path=$1
  if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    git rm --cached "$path" >/dev/null 2>&1 || true
  fi
}

commit_changes() {
  local repo_had_commits=$1

  if git diff --staged --quiet; then
    return 1
  fi

  if [[ "$repo_had_commits" == "true" ]] && upstream_exists; then
    git commit -m "push"
  elif [[ "$repo_had_commits" == "true" ]]; then
    git commit --amend -m "push"
  else
    git commit -m "push"
  fi

  return 0
}

upstream_exists() {
  git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1
}

run_with_https_credentials() {
  local askpass
  askpass=$(mktemp)
  cat >"$askpass" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == *Username* ]]; then
  printf '%s\n' "luascfl"
else
  printf '%s\n' "${GITHUB_TOKEN}"
fi
EOF
  chmod +x "$askpass"
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" "$@"
  local status=$?
  rm -f "$askpass"
  return $status
}

push_with_credentials() {
  local branch=$1

  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    run_with_https_credentials git push -u origin "$branch"
  else
    git push -u origin "$branch"
  fi
}

# --- FUNÇÃO 'pull_with_credentials' MODIFICADA ---
# Alterado de '--ff-only' para '--rebase --autostash' para
# lidar corretamente com históricos divergentes.
pull_with_credentials() {
  local branch=$1
  local pull_cmd="git pull --rebase --autostash origin $branch"

  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    if ! run_with_https_credentials $pull_cmd; then
        echo "Aviso: 'pull --rebase' falhou. Pode haver conflitos que exigem resolução manual." >&2
        # Permite que o script continue, mas o usuário pode precisar intervir
        return 1
    fi
  else
    if ! $pull_cmd; then
        echo "Aviso: 'pull --rebase' falhou. Pode haver conflitos que exigem resolução manual." >&2
        return 1
    fi
  fi
}

main "$@"
