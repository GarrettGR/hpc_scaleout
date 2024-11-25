#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_CONFIG_FILE="hpc_scaleout_config.toml"
readonly TEMPLATE_DIR="${SCRIPT_DIR}"
readonly DEFAULTS_FILE="${SCRIPT_DIR}/.defaults.toml"

REQUIRED_TOOLS=("yq" "jq" "envsubst")

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

check_dependencies() {
  local missing_tools=()

  for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
      missing_tools+=("$tool")
    fi
  done

  if [ ${#missing_tools[@]} -ne 0 ]; then
    log_error "Missing required tools: ${missing_tools[*]}"
    log_info "Please install the missing tools and try again"
    exit 1
  fi
}

toml_to_json() {
  local toml_file="$1"
  local json_output

  if [ ! -f "$toml_file" ]; then
    log_error "Configuration file not found: $toml_file"
    exit 1
  fi

  json_output=$(yq -o=json eval "$toml_file" 2>/dev/null)
  if [ $? -ne 0 ]; then
    log_error "Failed to parse TOML file"
    exit 1
  fi

  echo "$json_output"
}

merge_with_defaults() {
  local config_json="$1"
  local defaults_json="$2"

  echo "$config_json" "$defaults_json" | jq -s '.[1] * .[0]'
}

create_env_vars() {
  local json_data="$1"
  local prefix="$2"
  local vars=()

  process_json() {
    local data="$1"
    local current_prefix="$2"

    local keys=$(echo "$data" | jq -r 'paths(scalars) as $p | $p | join(".")')

    while IFS= read -r key_path; do
      [ -z "$key_path" ] && continue

      local value=$(echo "$data" | jq -r --arg path "$key_path" "getpath($path | split(\".\"))")

      local var_name="${current_prefix}_${key_path}"
      var_name="${var_name^^}" # convert to uppercase
      var_name="${var_name//\./_}" # replace dots with underscores
      var_name="${var_name//\-/_}" # replace hyphens with underscores

      export "$var_name=$value"
      vars+=("$var_name")
    done <<< "$keys"
  }

  process_json "$json_data" "$prefix"
  echo "${vars[@]}"
}

process_arithmetic_expressions() {
  local template_file="$1"
  local content

  content=$(<"$template_file")

  while [[ $content =~ \$\(\(([^\)]+)\)\) ]]; do
    local expr="${BASH_REMATCH[1]}"
    local orig_expr="${BASH_REMATCH[0]}"

    local eval_expr="$expr"
    for var in $(compgen -e | grep '^CONFIG_'); do
      if [[ $expr =~ $var ]]; then
        eval_expr="${eval_expr//$var/${!var}}"
      fi
    done

    local result
    result=$(($eval_expr))

    content="${content//$orig_expr/$result}"
  done

  echo "$content"
}

process_template() {
  local template_file="$1"
  local output_file="$2"
  local template_dir="$3"
  local output_dir="$4"

  mkdir -p "$(dirname "${output_dir}/${output_file}")"

  local array_info
  array_info=$(generate_array_info "$json_data")

  local temp_file
  temp_file=$(mktemp)

  process_array_expansions "${template_dir}/${template_file}" "$array_info" > "$temp_file"

  envsubst '${!CONFIG_*}' < "$temp_file" > "${output_dir}/${output_file}"

  rm -f "$temp_file"

  log_info "Processed template: ${template_file} -> ${output_file}"
}

generate_array_info() {
  local json_data="$1"

  echo "$json_data" | jq -r '
  paths(type == "array") as $p |
    {
      path: $p | join("."),
      length: getpath($p) | length,
      items: getpath($p) | map(
      if type == "object" then
        to_entries | map("\(.key)=\(.value)") | join(",")
      else
        tostring
      end
    )
  } | @json'
}

process_array_expansions() {
  local template_file="$1"
  local array_info="$2"
  local output=""
  local template_content

  template_content=$(<"$template_file")

  echo "$array_info" | jq -r '.[]' | while IFS= read -r array; do
    local path length items
    path=$(echo "$array" | jq -r '.path')
    length=$(echo "$array" | jq -r '.length')
    readarray -t items < <(echo "$array" | jq -r '.items[]')

    local length_var="CONFIG_${path//.//_}_LENGTH"
    length_var="${length_var^^}"
    export "${length_var}=${length}"

    local for_pattern="@for (.*?) in CONFIG_${path//.//_}@"
    if [[ $template_content =~ $for_pattern ]]; then
      local var_name="${BASH_REMATCH[1]}"
      local for_block
      for_block=$(echo "$template_content" | awk "/^@for.*CONFIG_${path//.//_}@/,/^@endfor/")

      local replacement=""
      for ((i=0; i<length; i++)); do
        local item_content="$for_block"
        local item="${items[$i]}"

        item_content="${item_content//@for*/}"
        item_content="${item_content//@endfor/}"

        if [[ $item == *"="* ]]; then
          while IFS='=' read -r key value; do
            item_content="${item_content//\${${var_name}.${key}}/${value}}"
          done < <(echo "$item" | tr ',' '\n')
        else
          item_content="${item_content//\${${var_name}}/${item}}"
        fi
        replacement+="$item_content"
      done

      template_content="${template_content//$for_block/$replacement}"
    fi
  done

  echo "$template_content"
}

process_templates() {
  local template_dir="$1"

  find "$template_dir" -type f -name "*.template" | while read -r template; do
    local relative_path="${template#"${template_dir}"/}"
    process_template "$relative_path" "$template_dir"
  done
}

show_usage() {
  cat << EOF
  Usage: $(basename "$0") [OPTIONS]

  Options:
  -c, --config FILE     Path to TOML configuration file (default: ${DEFAULT_CONFIG_FILE})
  -d, --defaults FILE   Path to defaults TOML file (default: ${DEFAULTS_FILE})
  -t, --template-dir DIR Path to template directory (default: ${TEMPLATE_DIR})
  -h, --help           Show this help message

  Example:
  $(basename "$0") -c config.toml -d defaults.toml -t ./templates
EOF
}


parse_args() {
  local config_file="$DEFAULT_CONFIG_FILE"
  local defaults_file="$DEFAULTS_FILE"
  local template_dir="$TEMPLATE_DIR"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config)
        config_file="$2"
        shift 2
      ;;
      -d|--defaults)
        defaults_file="$2"
        shift 2
      ;;
      -t|--template-dir)
        template_dir="$2"
        shift 2
      ;;
      -h|--help)
        show_usage
        exit 0
      ;;
      *)
        log_error "Unknown option: $1"
        show_usage
        exit 1
      ;;
    esac
  done

  echo "$config_file:$defaults_file:$template_dir"
}

main() {
  IFS=: read -r config_file defaults_file template_dir output_dir <<< "$(parse_args "$@")"

  check_dependencies

  log_info "Processing configuration file: $config_file"
  config_json=$(toml_to_json "$config_file")

  if [ -f "$defaults_file" ]; then
    log_info "Processing defaults file: $defaults_file"
    defaults_json=$(toml_to_json "$defaults_file")

    log_info "Merging configuration with defaults"
    json_data=$(merge_with_defaults "$config_json" "$defaults_json")
  else
    json_data="$config_json"
  fi

  log_info "Creating environment variables from configuration"
  create_env_vars "$json_data" "CONFIG"

  log_info "Processing templates from: $template_dir"
  process_templates "$template_dir" "$output_dir"

  log_info "Template processing completed successfully"
}

main "$@"
