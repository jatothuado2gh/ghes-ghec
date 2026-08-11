#!/usr/bin/env bash
# ============================================================
# GHES -> GHEC Rulesets Migration
# Organization + Repository Rulesets
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# Environment Inputs
# ------------------------------------------------------------

CSV_FILE="${CSV_FILE:-repos.csv}"

GH_PAT="${GH_PAT:-}"
if [[ -z "$GH_PAT" ]]; then
    echo "Set GH_PAT" >&2
    exit 1
fi

GH_SOURCE_PAT="${GH_SOURCE_PAT:-}"
if [[ -z "$GH_SOURCE_PAT" ]]; then
    echo "Set GH_SOURCE_PAT" >&2
    exit 1
fi

GHES_API_URL="${GHES_API_URL:-}"
if [[ -z "$GHES_API_URL" ]]; then
    echo "Set GHES_API_URL" >&2
    exit 1
fi

# Normal GHEC:
# github.com
#
# GHES DR:
# custom hostname

TARGET_HOST="${GH_TARGET_HOST:-github.com}"

if [[ -n "${TARGET_API_URL:-}" ]]; then
    TARGET_API_URL="$TARGET_API_URL"
elif [[ -n "${GH_TARGET_HOST:-}" ]]; then
    TARGET_API_URL="https://api.${GH_TARGET_HOST}"
else
    TARGET_API_URL="https://api.github.com"
fi

# ------------------------------------------------------------
# Source Host Resolution
# ------------------------------------------------------------

SOURCE_HOST="$(printf '%s' "$GHES_API_URL" | sed -E 's#^https?://##; s#/api/v3.*$##')"

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/rulesets-migration_$(date '+%Y%m%d_%H%M%S').log"

# Keep API response JSON on stdout while logs continue to display on the console.
exec 3>&1

write_log() {
    local level="$1"
    local message="$2"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
    printf '%s\n' "$line" >&3
    printf '%s\n' "$line" >> "$LOG_FILE"
}

COLOR_CYAN='\033[36m'
COLOR_YELLOW='\033[33m'
COLOR_GREEN='\033[32m'
COLOR_RED='\033[31m'
COLOR_RESET='\033[0m'

write_color() {
    local color="$1"
    shift
    printf '%b%s%b\n' "$color" "$*" "$COLOR_RESET" >&3
}

write_log INFO "Ruleset Migration Started"
write_log INFO "Source Host : $SOURCE_HOST"
write_log INFO "Target Host : $TARGET_HOST"

printf '\n' >&3


# ------------------------------------------------------------
# Dependency Validation
# ------------------------------------------------------------

for command_name in curl jq python3; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command not found: $command_name" >&2
        exit 1
    fi
done

# ------------------------------------------------------------
# Counters
# ------------------------------------------------------------

RepoProcessed=0
RulesetsReturned=0
OrganizationRulesetsCreated=0
OrganizationRulesetsSkipped=0
RepositoryRulesetsCreated=0
RepositoryRulesetsSkipped=0
RulesetsFailed=0

# Repository summaries are stored using a non-printable separator.
SUMMARY_SEPARATOR=$'\x1f'
declare -a AllRepoSummaries=()

# ------------------------------------------------------------
# GitHub API Wrapper
# ------------------------------------------------------------

invoke_github_api() {
    local host_name="$1"
    local token="$2"
    local method="$3"
    local endpoint="$4"
    local body="${5:-}"
    local uri response_file headers_file status response_body error_body retry_after
    local max_retries=5
    local retry_count=0

    if [[ "$host_name" == "$TARGET_HOST" ]]; then
        uri="${TARGET_API_URL}${endpoint}"
    else
        uri="https://${SOURCE_HOST}/api/v3${endpoint}"
    fi

    write_log INFO "$method $uri"

    while true; do

        response_file="$(mktemp)"
        headers_file="$(mktemp)"

        local -a curl_args=(
            --silent
            --show-error
            --location
            --request "$method"
            --header "Authorization: Bearer $token"
            --header "Accept: application/vnd.github+json"
            --header "X-GitHub-Api-Version: 2022-11-28"
            --dump-header "$headers_file"
            --output "$response_file"
            --write-out "%{http_code}"
            "$uri"
        )

        if [[ -n "$body" ]]; then
            curl_args+=(
                --header "Content-Type: application/json"
                --data "$body"
            )
        fi

        if ! status="$(curl "${curl_args[@]}")"; then
            rm -f "$response_file" "$headers_file"
            write_log ERROR "API Failed"
            write_log ERROR "curl request failed"
            return 1
        fi

        response_body="$(cat "$response_file")"

        if [[ "$status" =~ ^2 ]]; then
            rm -f "$response_file" "$headers_file"
            printf '%s' "$response_body"
            return 0
        fi

        retry_after="$(awk 'tolower($1)=="retry-after:" {print $2}' "$headers_file" | tr -d '\r')"

        if [[ "$status" =~ ^(403|429|502|503|504)$ ]] && [[ $retry_count -lt $max_retries ]]; then

            ((retry_count++))

            if [[ -n "$retry_after" ]]; then
                wait_time="$retry_after"
            else
                wait_time=$((5 ** retry_count))
            fi

            write_log WARN "GitHub API temporary failure detected (HTTP $status). Retry attempt $retry_count/$max_retries after $wait_time seconds."

            rm -f "$response_file" "$headers_file"
            sleep "$wait_time"
            continue
        fi

        rm -f "$response_file" "$headers_file"

        write_log ERROR "API Failed"
        write_log ERROR "Response status code does not indicate success: $status."

        if [[ -n "$response_body" ]]; then
            write_log ERROR "GitHub API Response Body:"
            while IFS= read -r error_body; do
                write_log ERROR "$error_body"
            done <<< "$response_body"
        fi

        return 1
    done
}

# ------------------------------------------------------------
# Clean Ruleset Payload
# ------------------------------------------------------------

get_clean_ruleset_payload() {
    local ruleset_json="$1"
    local ruleset_type="$2"

    jq --arg RulesetType "$ruleset_type" '
        del(
            .id,
            .node_id,
            ._links,
            .created_at,
            .updated_at,
            .source,
            .source_type,
            .ruleset_source,
            .current_user_can_bypass,
            .bypass_actors
        )
        | if has("conditions") then
            if .conditions == null then
                del(.conditions)
            elif (.conditions.ref_name? != null) then
                .conditions.ref_name.include = ((.conditions.ref_name.include // []) | map(tostring | gsub("\\\""; "")))
                | .conditions.ref_name.exclude = ((.conditions.ref_name.exclude // []) | map(tostring | gsub("\\\""; "")))
            else
                .
            end
          else
            .
          end
        | if $RulesetType == "Organization" and (.conditions.ref_name? != null) then
            .conditions.ref_name.include = ["~ALL"]
            | .conditions.ref_name.exclude = []
          else
            .
          end
        | if .target == "push" then
            del(.conditions)
          else
            .
          end
        | if has("rules") then
            .rules |= map(select(.type != "merge_queue"))
          else
            .
          end
    ' <<< "$ruleset_json"
}

# ------------------------------------------------------------
# Validate CSV
# ------------------------------------------------------------

if [[ ! -f "$CSV_FILE" ]]; then
    echo "CSV file not found: $CSV_FILE" >&2
    exit 1
fi

# Produce a safe tab-separated stream from the CSV while preserving the
# PowerShell column names and processing order.
mapfile -t REPOSITORY_ROWS < <(
    python3 - "$CSV_FILE" <<'PY'
import csv
import sys

path = sys.argv[1]
with open(path, newline='', encoding='utf-8-sig') as handle:
    reader = csv.DictReader(handle)
    required = ['ghes_org', 'ghes_repo', 'github_org', 'github_repo']
    missing = [name for name in required if name not in (reader.fieldnames or [])]
    if missing:
        raise SystemExit('Missing CSV columns: ' + ', '.join(missing))
    for row in reader:
        values = [row.get(name, '') or '' for name in required]
        print('\t'.join(value.replace('\t', ' ') for value in values))
PY
)

# ------------------------------------------------------------
# Ruleset Migration
# ------------------------------------------------------------

for repository_row in "${REPOSITORY_ROWS[@]}"; do
    IFS=$'\t' read -r SourceOrg SourceRepo TargetOrg TargetRepo <<< "$repository_row"

    ((RepoProcessed += 1))

    declare -a RepoSummaryRepositoryMigrated=()
    declare -a RepoSummaryRepositorySkipped=()

    printf '\n' >&3
    write_color "$COLOR_CYAN" "================================================"
    write_color "$COLOR_CYAN" "Source : $SourceOrg/$SourceRepo"
    write_color "$COLOR_CYAN" "Target : $TargetOrg/$TargetRepo"
    write_color "$COLOR_CYAN" "================================================"

    write_log INFO "Processing Repository"
    write_log INFO "Source Repository : $SourceOrg/$SourceRepo"
    write_log INFO "Target Repository : $TargetOrg/$TargetRepo"

    repo_failed=0

    if ! SourceRulesets="$(invoke_github_api "$SOURCE_HOST" "$GH_SOURCE_PAT" GET "/repos/$SourceOrg/$SourceRepo/rulesets?per_page=100")"; then
        write_color "$COLOR_RED" "[FAILED] Ruleset migration failed for $SourceRepo"
        ((RulesetsFailed += 1))
        repo_failed=1
    elif [[ -z "$SourceRulesets" || "$SourceRulesets" == "[]" || "$SourceRulesets" == "null" ]]; then
        write_log INFO "No rulesets found"
    else
        source_count="$(jq 'length' <<< "$SourceRulesets")"
        ((RulesetsReturned += source_count))

        while IFS= read -r Ruleset; do
            ruleset_name="$(jq -r '.name' <<< "$Ruleset")"
            ruleset_id="$(jq -r '.id' <<< "$Ruleset")"

            printf '\n' >&3
            write_color "$COLOR_CYAN" "Checking ruleset: $ruleset_name"

            if ! Details="$(invoke_github_api "$SOURCE_HOST" "$GH_SOURCE_PAT" GET "/repos/$SourceOrg/$SourceRepo/rulesets/$ruleset_id")"; then
                write_color "$COLOR_RED" "[FAILED] Ruleset migration failed for $SourceRepo"
                ((RulesetsFailed += 1))
                repo_failed=1
                break
            fi

            source_type="$(jq -r '.source_type // ""' <<< "$Details")"

            # =================================================
            # Organization Ruleset Handling
            # =================================================
            if [[ "$source_type" == "Organization" ]]; then
                write_color "$COLOR_YELLOW" "[ORGANIZATION RULESET] $ruleset_name"

                write_color "$COLOR_YELLOW" "[SKIPPED] Organization ruleset migration skipped. Only repository rulesets are supported."

                write_log INFO "Organization ruleset skipped. Only repository-level ruleset migration is supported."


                if ! TargetOrgRulesets="$(invoke_github_api "$TARGET_HOST" "$GH_PAT" GET "/orgs/$TargetOrg/rulesets?per_page=100")"; then
                    write_color "$COLOR_RED" "[FAILED] Ruleset migration failed for $SourceRepo"
                    ((RulesetsFailed += 1))
                    repo_failed=1
                    break
                fi

                ExistingOrgRuleset="$(jq --arg name "$ruleset_name" '[.[] | select(.name == $name)] | length' <<< "$TargetOrgRulesets")"

                if [[ "$ExistingOrgRuleset" -gt 0 ]]; then
                    write_color "$COLOR_YELLOW" "[SKIPPED] Organization ruleset already exists: $ruleset_name"
                    write_log INFO "Organization ruleset skipped (already exists): $ruleset_name"
                    ((OrganizationRulesetsSkipped += 1))
                fi

                continue
            fi

            # =================================================
            # Repository Ruleset Handling
            # =================================================
            if [[ "$source_type" == "Repository" ]]; then
                write_color "$COLOR_CYAN" "[REPOSITORY RULESET] $ruleset_name"

                if ! TargetRepoRulesets="$(invoke_github_api "$TARGET_HOST" "$GH_PAT" GET "/repos/$TargetOrg/$TargetRepo/rulesets?per_page=100")"; then
                    write_color "$COLOR_RED" "[FAILED] Ruleset migration failed for $SourceRepo"
                    ((RulesetsFailed += 1))
                    repo_failed=1
                    break
                fi

                ExistingRepoRuleset="$(jq --arg name "$ruleset_name" '[.[] | select(.name == $name)] | length' <<< "$TargetRepoRulesets")"

                if [[ "$ExistingRepoRuleset" -gt 0 ]]; then
                    write_color "$COLOR_YELLOW" "[SKIPPED] Repository ruleset already exists: $ruleset_name"
                    write_log INFO "Repository ruleset skipped (already exists): $ruleset_name"
                    ((RepositoryRulesetsSkipped += 1))
                    RepoSummaryRepositorySkipped+=("$ruleset_name")
                    continue
                fi

                write_color "$COLOR_CYAN" "[CREATING] Repository ruleset: $ruleset_name"

                RulesetType="Repository"

                if jq -e '.bypass_actors != null and (.bypass_actors | length) > 0' <<< "$Details" >/dev/null; then
                    write_log WARN "Bypass actors skipped for ruleset $ruleset_name - Identity based configurations are out of scope."
                fi

                if jq -e '.rules[]? | select(.type == "merge_queue")' <<< "$Details" >/dev/null; then
                    write_log WARN "Merge queue rule skipped for ruleset $ruleset_name - Target GHEC Ruleset API does not support migration of this rule configuration."
                fi

                Payload="$(get_clean_ruleset_payload "$Details" "$RulesetType")"

                if ! invoke_github_api "$TARGET_HOST" "$GH_PAT" POST "/repos/$TargetOrg/$TargetRepo/rulesets" "$Payload" >/dev/null; then
                    write_color "$COLOR_RED" "[FAILED] Ruleset migration failed for $SourceRepo"
                    ((RulesetsFailed += 1))
                    repo_failed=1
                    break
                fi

                write_color "$COLOR_GREEN" "[SUCCESS] Repository ruleset migrated: $ruleset_name"
                write_log INFO "Repository ruleset migrated: $ruleset_name"
                ((RepositoryRulesetsCreated += 1))
                RepoSummaryRepositoryMigrated+=("$ruleset_name")
            fi
        done < <(jq -c '.[]' <<< "$SourceRulesets")
    fi

    migrated_joined="$(printf '%s\036' "${RepoSummaryRepositoryMigrated[@]:-}")"
    skipped_joined="$(printf '%s\036' "${RepoSummaryRepositorySkipped[@]:-}")"
    AllRepoSummaries+=("$SourceOrg/$SourceRepo${SUMMARY_SEPARATOR}$TargetOrg/$TargetRepo${SUMMARY_SEPARATOR}${migrated_joined}${SUMMARY_SEPARATOR}${skipped_joined}")
done

# ------------------------------------------------------------
# Final Summary
# ------------------------------------------------------------

printf '\n' >&3
write_color "$COLOR_CYAN" "================================================"
write_color "$COLOR_CYAN" "Ruleset Migration Summary"
printf '\n' >&3
write_color "$COLOR_CYAN" "================================================"

for summary_record in "${AllRepoSummaries[@]}"; do
    IFS="$SUMMARY_SEPARATOR" read -r summary_source summary_target summary_migrated summary_skipped <<< "$summary_record"

    printf '\n' >&3
    write_color "$COLOR_CYAN" "Source Repository : $summary_source"
    write_color "$COLOR_CYAN" "Target Repository : $summary_target"

    printf '\n' >&3
    write_color "$COLOR_CYAN" "Repository Rulesets"
    printf '%s\n' "--------------------------------" >&3

    migrated_count=0
    if [[ -n "$summary_migrated" ]]; then
        IFS=$'\036' read -r -a migrated_rules <<< "$summary_migrated"
        for rule in "${migrated_rules[@]}"; do
            [[ -n "$rule" ]] && ((migrated_count += 1))
        done
    else
        migrated_rules=()
    fi

    printf 'Migrated : %s\n' "$migrated_count" >&3

    for rule in "${migrated_rules[@]:-}"; do
        [[ -n "$rule" ]] && write_color "$COLOR_GREEN" "$rule -> Migrated"
    done

    if [[ -n "$summary_skipped" ]]; then
        IFS=$'\036' read -r -a skipped_rules <<< "$summary_skipped"
        for rule in "${skipped_rules[@]}"; do
            [[ -n "$rule" ]] && write_color "$COLOR_YELLOW" "$rule -> Skipped (Already Exists)"
        done
    fi

    printf '\n' >&3
    write_color "$COLOR_CYAN" "================================================"
done

printf '\n' >&3
printf 'Repositories Processed : %s\n' "$RepoProcessed" >&3
printf 'Failed : %s\n' "$RulesetsFailed" >&3
printf 'Log File : %s\n' "$LOG_FILE" >&3
write_color "$COLOR_CYAN" "================================================"
