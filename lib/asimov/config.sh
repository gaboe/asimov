#!/usr/bin/env bash
# shellcheck shell=bash
#
# The optional config file at ~/.config/asimov/config.
#
# Grammar: [section] headers, key = value lines, # comments, blank lines.
# Unrecognised sections and keys are ignored here and reported by `asimov doctor`,
# so a typo is visible without breaking a run.

# Populate ASIMOV_CONFIG_* from the config file. A missing file is not an error.
load_config() {
    ASIMOV_CONFIG_FIXED_DIRS_ENABLED=false
    ASIMOV_CONFIG_EXTRA_FIXED_DIRS=()
    ASIMOV_CONFIG_EXTRA_SENTINELS=()
    ASIMOV_CONFIG_DISABLED_SENTINELS=()
    ASIMOV_CONFIG_SCAN_DIRS=()
    ASIMOV_CONFIG_SCAN_DIRS_ONLY=()
    ASIMOV_CONFIG_EXTRA_SKIP_PATHS=()
    ASIMOV_CONFIG_KEEP_ONLY_DIRS=()
    ASIMOV_CONFIG_KEEP_ONLY_KEEP_RULES=()
    ASIMOV_CONFIG_KEEP_ONLY_KEEPS=()

    [[ -f "$ASIMOV_CONFIG_FILE" ]] || return 0

    local section="" line key value keep_only_rule=-1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^\[([a-z_]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "$line" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%"${value##*[![:space:]]}"}"

            case "${section}:${key}" in
                fixed_dirs:enabled)
                    ASIMOV_CONFIG_FIXED_DIRS_ENABLED="$value"
                    ;;
                fixed_dirs:extra)
                    value="${value/#\~/$HOME}"
                    ASIMOV_CONFIG_EXTRA_FIXED_DIRS+=("$value")
                    ;;
                scan:extra)
                    value="${value/#\~/$HOME}"
                    ASIMOV_CONFIG_SCAN_DIRS+=("$value")
                    ;;
                scan:dirs)
                    value="${value/#\~/$HOME}"
                    ASIMOV_CONFIG_SCAN_DIRS_ONLY+=("$value")
                    ;;
                sentinels:extra)
                    ASIMOV_CONFIG_EXTRA_SENTINELS+=("$value")
                    ;;
                sentinels:disabled)
                    ASIMOV_CONFIG_DISABLED_SENTINELS+=("$value")
                    ;;
                skip_paths:extra)
                    value="${value/#\~/$HOME}"
                    ASIMOV_CONFIG_EXTRA_SKIP_PATHS+=("$value")
                    ;;
                keep_only:dir)
                    value="${value/#\~/$HOME}"
                    ASIMOV_CONFIG_KEEP_ONLY_DIRS+=("$value")
                    keep_only_rule=$((${#ASIMOV_CONFIG_KEEP_ONLY_DIRS[@]} - 1))
                    ;;
                keep_only:keep)
                    if [[ "$keep_only_rule" -ge 0 ]]; then
                        ASIMOV_CONFIG_KEEP_ONLY_KEEP_RULES+=("$keep_only_rule")
                        ASIMOV_CONFIG_KEEP_ONLY_KEEPS+=("$value")
                    fi
                    ;;
            esac
        fi
    done < "$ASIMOV_CONFIG_FILE"
}
