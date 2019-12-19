#!/bin/bash
# CLI for working with CircleCI Workflows
#
# Run `./workflows-cli.sh` to see usage.
#
# Required command line dependencies:
#   * ``aws``
#   * ``jq``

if [[ ! $(which aws) ]]; then
  echo "Missing aws. Install: https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html"
  exit 1
fi

if [[ ! $(which jq) ]]; then
  echo "Missing jq. Install: https://stedolan.github.io/jq/download/"
  exit 1
fi

declare COMMAND

# Common options
if [[ -z "$WORKFLOW_LOCK_KEY" ]]; then
  echo "Environment variable WORKFLOW_LOCK_KEY is required"
  exit 1
fi
if [[ -z "$WORKFLOW_DYNAMODB_TABLE" ]]; then
  echo "Environment variable WORKFLOW_DYNAMODB_TABLE is required"
  exit 1
fi

# Options for the `ls` command
declare ALL_STATUSES="RUNNING,QUEUED,SUCCESS,FAILED,CANCELLED"
declare COLUMNS=workflow_id,status,username,committed_at,acquired_at,released_at,commit
declare LIMIT=100
declare POLL_INTERVAL=2
declare QUIET
declare STATUSES="QUEUED,RUNNING"
declare WATCH

# Options for the `cancel` command
declare WORKFLOW_ID

# Convert list of statuses to a map
STATUS_MAP="$(echo "$ALL_STATUSES" | jq -R 'split(",") | INDEX(.)' -)"

# Static map of DynamoDB attribute name to column configuration for displaying workflows
COLUMN_CONFIG='{
  "columns": {
    "workflow_id": {
      "title": "WORKFLOW ID",
      "type": "S"
    },
    "status": {
      "title": "STATUS",
      "type": "S"
    },
    "username": {
      "title": "USERNAME",
      "type": "S"
    },
    "committed_at": {
      "title": "COMMITTED AT",
      "type": "N",
      "is_date": true
    },
    "created_at": {
      "title": "CREATED AT",
      "type": "N",
      "is_date": true
    },
    "acquired_at": {
      "title": "ACQUIRED AT",
      "type": "N",
      "is_date": true
    },
    "released_at": {
      "title": "RELEASED AT",
      "type": "N",
      "is_date": true
    },
    "commit": {
      "title": "COMMIT",
      "type": "S"
    }
  }
}'
ALL_COLUMNS="$(echo "$COLUMN_CONFIG" | jq -r '.columns | keys | join(",")' -)"

function queryWorkflows() {
  local key_values="$(
    echo '{}' \
      | jq --arg k "$WORKFLOW_LOCK_KEY" '.[":key"].S = $k' -)"
  if [[ "$STATUSES" == "all" ]]; then
    aws dynamodb query \
      --table-name "$WORKFLOW_DYNAMODB_TABLE" \
      --key-condition-expression '#key = :key' \
      --expression-attribute-names '{"#key": "key"}' \
      --expression-attribute-values "$key_values" \
      --max-items "$LIMIT"
  else
    local statuses_valid="$(
      echo "$STATUSES" \
        | jq -R --argjson statuses "$STATUS_MAP" 'split(",") | map(in($statuses)) | all' -)"
    if [[ "$statuses_valid" != "true" ]]; then
      echo "One or more of the provided statuses are not valid: $STATUSES"
      exit 1
    fi
    local status_names="$(
      echo "$STATUSES" \
        | jq -Rr '. | split(",") | map(":\(.)") | join(", ")' -)"
    local filter_expression="#status IN ($status_names)"
    local status_values="$(
      echo "$STATUSES" \
        | jq -R '. | split(",") | reduce .[] as $item ({}; .[":\($item)"].S = $item)' -)"
    # Merge the two values objects
    local values="$(
      echo "[${key_values}, ${status_values}]" \
        | jq '.[0] * .[1]' -)"
    aws dynamodb query \
      --table-name "$WORKFLOW_DYNAMODB_TABLE" \
      --key-condition-expression '#key = :key' \
      --filter-expression "$filter_expression" \
      --expression-attribute-names '{"#key": "key", "#status": "status"}' \
      --expression-attribute-values "$values" \
      --max-items "$LIMIT"
  fi
}

function displayWorkflows() {
  if [[ -n "$QUIET" ]]; then
    # Only print workflow IDs
    echo "$1" | jq -r '.Items | map(.workflow_id.S) | join("\n")' -
  else
    local column_array="$(echo "$COLUMNS" | jq -R 'split(",")' -)"
    local columns_valid="$(
      echo "$column_array" \
        | jq --argjson columns "$COLUMN_CONFIG" 'map(in($columns.columns)) | all' -)"
    if [[ "$columns_valid" != "true" ]]; then
      echo "One or more of the provided columns are not valid: $COLUMNS"
      exit 1
    fi
    (
      # Render titles
      echo "$column_array" \
        | jq -r \
            --argjson config "$COLUMN_CONFIG" \
            'map($config.columns[.].title) | join(",")';
      # Render title row delimiter
      echo "$column_array" | jq -r 'map("---") | join(",")';
      # Render workflow rows
      echo "$1" \
        | jq -r \
            --argjson columns "$column_array" \
            --argjson config "$COLUMN_CONFIG" \
            '
            def ornull: . // "(NULL)";

            def todate:
              if .
              then . | tonumber | strftime("%Y-%m-%dT%H:%M:%SZ")
              else null
              end | ornull;

            .Items
              | map(
                . as $item
                | (
                  $columns
                  | map(
                    if $config.columns[.].is_date
                    then ($item[.][$config.columns[.].type] | todate)
                    else ($item[.][$config.columns[.].type] | ornull)
                    end
                  )
                )
                | join(",")
              )
              | .[]
              ' -
    ) | column -t -s ','
  fi
}

function listWorkflows() {
  local workflows
  if [[ -z "$WATCH" ]]; then
    workflows="$(queryWorkflows)"
    if [[ $? -ne 0 ]]; then
      echo "$workflows"
      exit 1
    fi
    displayWorkflows "$workflows"
  else
    while true; do
      workflows="$(queryWorkflows)"
      if [[ $? -ne 0 ]]; then
        echo "$workflows"
        exit 1
      fi
      clear
      printf "Press [CTRL+C] to stop..\n\n"
      displayWorkflows "$workflows"
      sleep "$POLL_INTERVAL"
    done
  fi
}

function getWorkflowKey() {
  local workflow_id="$1"
  local values="$(
    echo '{}' \
      | jq --arg k "$WORKFLOW_LOCK_KEY" '.[":key"].S = $k' - \
      | jq --arg id "$workflow_id" '.[":workflow_id"].S = $id' -)"
  local result="$(
    aws dynamodb query \
      --table-name "$WORKFLOW_DYNAMODB_TABLE" \
      --index-name workflow_id \
      --key-condition-expression '#key = :key AND #workflow_id = :workflow_id' \
      --expression-attribute-names '{"#key": "key", "#workflow_id": "workflow_id"}' \
      --expression-attribute-values "$values" \
      --max-items 1)"
  if [[ -z "$result" || "$(echo "$result" | jq -r .Count -)" == 0 ]]; then
    echo "No item found in $WORKFLOW_DYNAMODB_TABLE with workflow_id=$workflow_id: $result"
    exit 1
  fi
  local committed_at="$(echo "$result" | jq -r .Items[0].committed_at.N -)"
  echo '{}' \
    | jq --arg k "$WORKFLOW_LOCK_KEY" '.key.S = $k' - \
    | jq --arg t "$committed_at" '.committed_at.N = $t' -
}

function updateWorkflow() {
  local workflow_id="$1"
  local status="$2"
  local values="$(echo '{}' | jq --arg s "$status" '.[":status"].S = $s' -)"
  aws dynamodb update-item \
    --table-name "$WORKFLOW_DYNAMODB_TABLE" \
    --key "$(getWorkflowKey "$workflow_id")" \
    --update-expression 'SET #status = :status' \
    --expression-attribute-names '{"#status": "status"}' \
    --expression-attribute-values "$values" \
    --return-values ALL_NEW
}

function parseOptions() {
  while getopts "c:k:l:p:s:t:qw" option; do
    case "${option}" in
      c)
        COLUMNS="${OPTARG}"
        if [[ "$COLUMNS" == "all" ]]; then
          COLUMNS="$ALL_COLUMNS"
        fi
        ;;
      k)
        WORKFLOW_LOCK_KEY="${OPTARG}"
        ;;
      l)
        LIMIT="${OPTARG}"
        ((LIMIT > 0 && LIMIT <= 100)) || usage
        ;;
      p)
        POLL_INTERVAL="${OPTARG}"
        ((POLL_INTERVAL > 0 && POLL_INTERVAL <= 60)) || usage
        ;;
      q)
        QUIET=1
        ;;
      s)
        STATUSES="${OPTARG}"
        ;;
      t)
        WORKFLOW_DYNAMODB_TABLE="${OPTARG}"
        ;;
      w)
        WATCH=1
        ;;
      *)
        usage
        ;;
    esac
  done
}

function usage() {
  printf "Usage:\n\t./workflows-cli.sh <command> [<arg>...] [options]\n"
  printf "\nCommands:\n"
  printf "\tls\t\t\tList workflows\n"
  printf "\tcancel <workflow-id>\tCancel a workflow\n"
  printf "\nList Options:\n"
  printf "\t-c <column>\tInclude specific columns in the table. Either provide 'all' or a comma-separated list\n\t\t\tincluding one or more of: %s\n\t\t\t(default: %s)\n" "$ALL_COLUMNS" "$COLUMNS"
  printf "\t-l <count>\tLimit the number of workflows returned. Must be between 1 and 100 (default: %s)\n" "$LIMIT"
  printf "\t-p <seconds>\tPolling interval when watching for updates. Must be between 1 and 60 (default: %s)\n" "$POLL_INTERVAL"
  printf "\t-q\tQuiet output, i.e. only print workflow IDs\n"
  printf "\t-s <status>\tFilter workflows by status. Either provide 'all' or a comma-separated list\n\t\t\tincluding one or more of: %s\n\t\t\t(default: %s)\n" "$ALL_STATUSES" "$STATUSES"
  printf "\t-w\t\tWatch for updates. This clears the terminal.\n"
  printf "\nCommon Options:\n"
  printf "\t-k <key>\tDynamoDB primary key value (default: %s)\n" "$WORKFLOW_LOCK_KEY"
  printf "\t-t <table>\tDynamoDB table (default: %s)\n" "$WORKFLOW_DYNAMODB_TABLE"
  exit 1
}

COMMAND="$1"
[[ -z "$COMMAND" ]] && usage
case "$COMMAND" in
  "ls")
    shift 1
    parseOptions $@
    listWorkflows
    ;;
  "cancel")
    WORKFLOW_ID="$2"
    [[ -z "$WORKFLOW_ID" ]] && usage
    shift 2
    parseOptions $@
    updateWorkflow "$WORKFLOW_ID" 'CANCELLED'
    ;;
  *)
    usage
    ;;
esac
