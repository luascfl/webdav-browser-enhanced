#!/usr/bin/env bash

set -euo pipefail

main() {
  ensure_dependencies
  ensure_github_token
  ensure_amo_credentials

  local repo_dir repo_name script_rel
  repo_dir=$(pwd)
  repo_name=$(basename "$repo_dir")
  script_rel=$(script_relative_path "$repo_dir")

  init_git_repo
  local repo_had_commits="false"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    repo_had_commits="true"
  fi

  local current_branch remote_url
  current_branch=$(ensure_main_branch)
  remote_url=$(resolve_remote_url "$repo_name")

  if remote_exists "origin"; then
    echo "Remoto 'origin' já existe. Pulando criação no GitHub." >&2
  else
    create_github_repo_if_needed "$repo_name"
  fi
  ensure_remote "$remote_url"
  sync_with_remote "$remote_url" "$current_branch"

  # A submissão ao AMO acontece antes do push para evitar publicar código que falha na revisão.
  submit_extension_to_amo

  stage_files_excluding_sensitive "$script_rel"
  if commit_changes "$repo_had_commits"; then
    repo_had_commits="true"
  else
    echo "Nenhuma alteração nova para commitar. Prosseguindo com push." >&2
  fi

  push_with_credentials "$current_branch"
  echo "Push concluído com sucesso: $remote_url" >&2
}

ensure_dependencies() {
  local deps=(git curl web-ext python3)
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      echo "Erro: dependência '$dep' não encontrada no PATH." >&2
      exit 1
    fi
  done
}

ensure_github_token() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    return
  fi

  if load_secret_into_var GITHUB_TOKEN GITHUB_TOKEN GITHUB_TOKEN.txt; then
    return
  fi

  echo "Erro: defina a variável GITHUB_TOKEN ou crie um arquivo GITHUB_TOKEN(.txt)." >&2
  exit 1
}

ensure_amo_credentials() {
  local missing=0

  if ! load_secret_into_var AMO_API_KEY AMO_API_KEY AMO_API_KEY.txt; then
    create_secret_placeholder AMO_API_KEY.txt "chave AMO API Key"
    echo "Erro: defina AMO_API_KEY ou crie AMO_API_KEY(.txt)." >&2
    missing=1
  fi

  if ! load_secret_into_var AMO_API_SECRET AMO_API_SECRET AMO_API_SECRET.txt; then
    create_secret_placeholder AMO_API_SECRET.txt "chave AMO API Secret"
    echo "Erro: defina AMO_API_SECRET ou crie AMO_API_SECRET(.txt)." >&2
    missing=1
  fi

  if [[ $missing -ne 0 ]]; then
    echo "Dica: gere as credenciais em https://addons.mozilla.org/developers/addon/api/key e cole a chave/segredo na primeira linha de cada arquivo." >&2
    exit 1
  fi
}

create_secret_placeholder() {
  local filename=$1
  local label=$2
  local amo_url="https://addons.mozilla.org/developers/addon/api/key"

  if [[ -e "$filename" ]]; then
    return
  fi

  cat >"$filename" <<EOF

# Cole sua $label na primeira linha deste arquivo.
# Gere novas credenciais no Portal de Desenvolvedores do Firefox: $amo_url
EOF

  local current_dir
  current_dir=$(pwd)
  echo "Arquivo '$filename' criado em '$current_dir'." >&2
  echo "Acesse $amo_url para gerar a sua $label e cole o valor na primeira linha de '$filename'." >&2
}

load_secret_into_var() {
  local var_name=$1
  shift

  if [[ -n "${!var_name:-}" ]]; then
    return 0
  fi

  local value candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      value=$(read_first_line "$candidate") || continue
      if [[ -n "$value" ]]; then
        printf -v "$var_name" '%s' "$value"
        export "$var_name"
        return 0
      fi
    fi
  done

  return 1
}

read_first_line() {
  local path=$1
  python3 - "$path" <<'PY'
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
}

script_relative_path() {
  local repo_dir=$1
  local script_path

  if command -v realpath >/dev/null 2>&1; then
    script_path=$(realpath "$0")
    realpath --relative-to="$repo_dir" "$script_path" || basename "$script_path"
  else
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

init_git_repo() {
  if [[ ! -d .git ]]; then
    git init
  fi
}

ensure_main_branch() {
  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || true)

  if [[ -z "$current_branch" ]]; then
    git symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || git branch -M main
    current_branch="main"
  elif [[ "$current_branch" != "main" ]]; then
    git branch -M "$current_branch" main
    current_branch="main"
  fi

  echo "$current_branch"
}

resolve_remote_url() {
  local repo_name=$1
  local protocol=${GITHUB_REMOTE_PROTOCOL:-https}
  local user=${GITHUB_USER:-luascfl}

  case "$protocol" in
    ssh)
      echo "git@github.com:${user}/${repo_name}.git"
      ;;
    https)
      echo "https://github.com/${user}/${repo_name}.git"
      ;;
    *)
      echo "Erro: protocolo $protocol não suportado. Use 'https' ou 'ssh'." >&2
      exit 1
      ;;
  esac
}

create_github_repo_if_needed() {
  local repo_name=$1
  local response_file status

  response_file=$(mktemp)
  status=$(create_github_repo "$repo_name" "$response_file")
  handle_create_repo_response "$status" "$response_file" "$repo_name"
  rm -f "$response_file"
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
      echo "Repositório '$repo_name' criado no GitHub." >&2
      ;;
    422)
      echo "Repositório '$repo_name' já existe. Reutilizando remoto." >&2
      ;;
    401|403)
      echo "Erro de autenticação ao criar o repositório (status $http_status)." >&2
      cat "$response_file" >&2
      exit 1
      ;;
    000)
      echo "Falha na chamada ao GitHub (status vazio). Verifique sua conexão." >&2
      exit 1
      ;;
    *)
      echo "Erro ao criar repositório no GitHub (status $http_status):" >&2
      cat "$response_file" >&2
      exit 1
      ;;
  esac
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
      echo "Erro: remoto 'origin' configurado para '$current_url'. Ajuste manualmente." >&2
      exit 1
    fi
  else
    git remote add origin "$expected_url"
  fi
}

sync_with_remote() {
  local remote_url=$1
  local branch=$2

  if git ls-remote --exit-code --heads "$remote_url" "$branch" >/dev/null 2>&1; then
    echo "Sincronizando branch remoto '$branch' (pull --rebase)..." >&2
    pull_with_credentials "$branch" || {
      echo "Aviso: pull falhou; resolva conflitos antes de prosseguir." >&2
      exit 1
    }
  else
    echo "Branch remoto '$branch' não encontrado. Primeiro push presumido." >&2
  fi
}

submit_extension_to_amo() {
  local channel=${AMO_CHANNEL:-listed}
  case "$channel" in
    listed|unlisted)
      ;;
    *)
      echo "Erro: AMO_CHANNEL deve ser 'listed' ou 'unlisted'." >&2
      exit 1
      ;;
  esac

  ensure_webext_ignore

  local artifacts_dir=${AMO_ARTIFACTS_DIR:-.web-ext-artifacts}
  mkdir -p "$artifacts_dir"

  local metadata_file=${AMO_METADATA_FILE:-amo-metadata.json}
  if [[ ! -f "$metadata_file" ]]; then
    cat >"$metadata_file" <<'EOF'
{
  "version": {
    "custom_license": {
      "name": {
        "en-US": "Mozilla Public License 2.0"
      },
      "text": {
        "en-US": "Mozilla Public License 2.0. Full text: https://www.mozilla.org/MPL/2.0/"
      }
    }
  }
}
EOF
  fi

  local cmd=(web-ext sign
    --api-key "$AMO_API_KEY"
    --api-secret "$AMO_API_SECRET"
    --channel "$channel"
    --artifacts-dir "$artifacts_dir"
    --amo-metadata "$metadata_file"
  )

  local ignore_patterns=(
    "AMO_API_KEY"
    "AMO_API_KEY.txt"
    "AMO_API_SECRET"
    "AMO_API_SECRET.txt"
    "GITHUB_TOKEN"
    "GITHUB_TOKEN.txt"
    "create_firefox-amo_push_github.sh"
    "install-addon-policy.sh"
    "README.md"
    "updates.json"
    "screenshots/**"
    ".web-ext-artifacts/**"
  )
  for pattern in "${ignore_patterns[@]}"; do
    cmd+=(--ignore-files "$pattern")
  done

  if [[ -n "${AMO_SOURCE_DIR:-}" ]]; then
    cmd+=(--source-dir "$AMO_SOURCE_DIR")
  fi

  echo "Enviando extensão ao Firefox AMO (canal: $channel)..." >&2
  "${cmd[@]}"
  echo "Submissão ao AMO concluída. Acompanhe o status no painel do desenvolvedor." >&2
}

stage_files_excluding_sensitive() {
  local script_rel=$1
  ensure_sensitive_gitignore
  git add --all

  local protected=(
    "$script_rel"
    "GITHUB_TOKEN"
    "GITHUB_TOKEN.txt"
    "AMO_API_KEY"
    "AMO_API_KEY.txt"
    "AMO_API_SECRET"
    "AMO_API_SECRET.txt"
  )

  for path in "${protected[@]}"; do
    protect_path "$path"
  done
}

ensure_sensitive_gitignore() {
  local gitignore=".gitignore"
  local entries=(
    "GITHUB_TOKEN"
    "GITHUB_TOKEN.txt"
    "AMO_API_KEY"
    "AMO_API_KEY.txt"
    "AMO_API_SECRET"
    "AMO_API_SECRET.txt"
    ".web-ext-artifacts/"
  )
  local appended=0

  if [[ ! -f "$gitignore" ]]; then
    printf "%s\n" "${entries[@]}" >"$gitignore"
    return
  fi

  local entry
  for entry in "${entries[@]}"; do
    if ! grep -Fxq "$entry" "$gitignore"; then
      if [[ $appended -eq 0 ]]; then
        if [[ -s "$gitignore" ]] && [[ $(tail -c1 "$gitignore" 2>/dev/null || printf '') != $'\n' ]]; then
          printf "\n" >>"$gitignore"
        fi
        appended=1
      fi
      printf "%s\n" "$entry" >>"$gitignore"
    fi
  done
}

ensure_webext_ignore() {
  local ignore_file=".web-extignore"
  local entries=(
    ".git/"
    ".github/"
    ".web-ext-artifacts/"
    ".web-ext-ignore"
    ".webextignore"
    "GITHUB_TOKEN"
    "GITHUB_TOKEN.txt"
    "AMO_API_KEY"
    "AMO_API_KEY.txt"
    "AMO_API_SECRET"
    "AMO_API_SECRET.txt"
    "create_firefox-amo_push_github.sh"
    "install-addon-policy.sh"
    "updates.json"
    "README.md"
    "screenshots/"
  )
  local appended=0

  if [[ ! -f "$ignore_file" ]]; then
    printf "%s\n" "${entries[@]}" >"$ignore_file"
    return
  fi

  local entry
  for entry in "${entries[@]}"; do
    if ! grep -Fxq "$entry" "$ignore_file"; then
      if [[ $appended -eq 0 ]]; then
        if [[ -s "$ignore_file" ]] && [[ $(tail -c1 "$ignore_file" 2>/dev/null || printf '') != $'\n' ]]; then
          printf "\n" >>"$ignore_file"
        fi
        appended=1
      fi
      printf "%s\n" "$entry" >>"$ignore_file"
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
  printf '%s\n' "${GITHUB_USER:-luascfl}"
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

pull_with_credentials() {
  local branch=$1
  local pull_cmd=(git pull --rebase --autostash origin "$branch")

  if [[ "${GITHUB_REMOTE_PROTOCOL:-https}" == "https" ]]; then
    run_with_https_credentials "${pull_cmd[@]}"
  else
    "${pull_cmd[@]}"
  fi
}

main "$@"
