#!/usr/bin/env bash
# shellcheck shell=bash
#
# Turning a list of paths into Time Machine exclusions.

# Record an excluded path: log for counting, compute size only with --stats.
record_excluded_path() {
    local path="$1"
    local message="$2"
    if [[ -n "$ASIMOV_STATS" ]]; then
        local rawsize size_human
        rawsize=$(du -sk "${path}" 2>/dev/null | cut -f1 || echo "0")
        echo "$rawsize" >> "$ASIMOV_SIZE_LOG"
        if [[ -z "$ASIMOV_QUIET" ]]; then
            size_human="$(format_size_kb "$rawsize")"
            printf '%s\n' "- ${message} (${size_human})."
        fi
    else
        echo "0" >> "$ASIMOV_SIZE_LOG"
        if [[ -z "$ASIMOV_QUIET" ]]; then
            printf '%s\n' "- ${message}."
        fi
    fi
}

# Process newline-separated paths from stdin: check the excluded-path cache,
# call tmutil addexclusion (unless dry-run), and log sizes.
#
# Performance notes (learned the hard way):
# - tmutil addexclusion takes ~11s per call (IPC with TM daemon). This dominates runtime.
# - Batching (tmutil addexclusion path1 path2 ...) provides NO speed benefit — tmutil
#   processes paths sequentially at ~11s each. Worse: one bad path (e.g. a read-only
#   dir in Go's module cache) fails the entire batch, wasting all accumulated time.
# - Spotlight (mdfind) can be stale: recently excluded paths may not appear in the index.
#   Without a guard, this causes re-excluding already-done paths (~11s each, wasted).
# - Three-layer defense against wasted tmutil calls:
#   1. Bulk grep against Spotlight + persistent state (instant, catches ~90%)
#   2. Filter descendants of fixed dirs (instant, catches ~5%)
#   3. tmutil isexcluded per-path guard (fast, catches remaining stale entries)
exclude_paths_from_stdin() {
    local path
    local -a all_paths=()

    # A kept child and its descendants must remain available to Time Machine.
    local kept_path
    while IFS=$'\n' read -r path; do
        [[ -e "$path" && ! -L "$path" ]] || continue
        for kept_path in ${ASIMOV_KEEP_ONLY_PRESERVED_PATHS[@]+"${ASIMOV_KEEP_ONLY_PRESERVED_PATHS[@]}"}; do
            if [[ "$path" == "$kept_path" || "$path" == "$kept_path/"* ]]; then
                continue 2
            fi
        done
        all_paths+=("$path")
    done
    [[ ${#all_paths[@]} -eq 0 ]] && return 0

    # Layer 1: Bulk filter against excluded-path cache (1 grep vs N subprocess spawns).
    # NEVER use per-path grep in a loop — spawning a subprocess per candidate is O(N)
    # process creation overhead that dominated runtime with ~15k mdfind candidates.
    verbose_timing "Filtering ${#all_paths[@]} paths against excluded-path cache…"
    local -a to_exclude=()
    local already_excluded=0
    if [[ -f "$ASIMOV_EXCLUDED_CACHE" ]]; then
        local new_paths_str
        new_paths_str="$(printf '%s\n' "${all_paths[@]}" | grep -Fxvf "$ASIMOV_EXCLUDED_CACHE" || true)"
        if [[ -n "$new_paths_str" ]]; then
            while IFS= read -r path; do
                to_exclude+=("$path")
            done <<< "$new_paths_str"
        fi
        already_excluded=$(( ${#all_paths[@]} - ${#to_exclude[@]} ))
        if [[ -n "$ASIMOV_VERBOSE" && $already_excluded -gt 0 ]]; then
            echo "- ${already_excluded} paths already excluded, skipping."
        fi
    else
        to_exclude=("${all_paths[@]}")
    fi
    verbose_timing "Filtered: ${#to_exclude[@]} new, ${already_excluded} already excluded"

    # Layer 2: Filter descendants of enabled built-in fixed dirs and configured
    # extra fixed dirs — they'll be excluded unconditionally later, so calling
    # tmutil on them individually is wasted (~11s each).
    local -a effective_fixed_dirs=()
    if [[ "$ASIMOV_CONFIG_FIXED_DIRS_ENABLED" == "true" ]]; then
        effective_fixed_dirs=("${ASIMOV_FIXED_DIRS[@]}")
    fi
    local configured_fixed_dir
    for configured_fixed_dir in ${ASIMOV_CONFIG_EXTRA_FIXED_DIRS[@]+"${ASIMOV_CONFIG_EXTRA_FIXED_DIRS[@]}"}; do
        effective_fixed_dirs+=("$configured_fixed_dir")
    done

    if [[ ${#effective_fixed_dirs[@]} -gt 0 && ${#to_exclude[@]} -gt 0 ]]; then
        local -a filtered_exclude=()
        for path in "${to_exclude[@]}"; do
            local under_fixed=false
            local fixed_dir
            for fixed_dir in "${effective_fixed_dirs[@]}"; do
                if [[ "$path" == "${fixed_dir}/"* ]]; then
                    under_fixed=true
                    break
                fi
            done
            if [[ "$under_fixed" == false ]]; then
                filtered_exclude+=("$path")
            fi
        done
        if [[ ${#filtered_exclude[@]} -lt ${#to_exclude[@]} ]]; then
            verbose_timing "Skipped $((${#to_exclude[@]} - ${#filtered_exclude[@]})) paths inside fixed dirs"
            to_exclude=("${filtered_exclude[@]+"${filtered_exclude[@]}"}")
        fi
    fi

    [[ ${#to_exclude[@]} -eq 0 ]] && {
        verbose_timing "Nothing to exclude (${already_excluded} already excluded)"
        return 0
    }
    verbose_timing "${#to_exclude[@]} to exclude, ${already_excluded} already excluded"

    # Layer 3: tmutil isexcluded guard before the expensive addexclusion (~11s each).
    # This is the ground truth — catches paths the Spotlight cache missed (stale index,
    # interrupted previous runs, or exclusions added outside Asimov — e.g. a manually
    # excluded parent like ~/.nvm). v0.5.0 removed this check; re-adding it cut runtime
    # from 73 min to 79s on a real system with ~460 dependency paths.
    #
    # --dry-run takes this exact same path so the preview matches a real run: it still
    # runs the read-only `tmutil isexcluded` guard, but prints "Would exclude" instead
    # of calling addexclusion and never persists state.
    verbose_timing "Excluding ${#to_exclude[@]} paths via tmutil…"
    [[ -z "$ASIMOV_DRY_RUN" && -z "$ASIMOV_NO_WRITE_CACHE" ]] && ensure_cache_dir
    local tmutil_i=0 skipped_already=0
    for path in "${to_exclude[@]}"; do
        tmutil_i=$((tmutil_i + 1))
        # Ground-truth check: is this path actually already excluded?
        if tmutil isexcluded "$path" 2>/dev/null | grep -Fq '[Excluded]'; then
            skipped_already=$((skipped_already + 1))
            # Persist so we skip it via the fast cache next time (not in dry-run / no-write)
            [[ -z "$ASIMOV_DRY_RUN" && -z "$ASIMOV_NO_WRITE_CACHE" ]] && append_state "$path" "$ASIMOV_EXCLUDED_STATE"
            if [[ -n "$ASIMOV_VERBOSE" ]]; then
                echo "- ${path} is already excluded, skipping."
            fi
            continue
        fi
        if [[ -n "$ASIMOV_DRY_RUN" ]]; then
            record_excluded_path "$path" "Would exclude: ${path}"
            continue
        fi
        local path_start=$SECONDS
        # Time Machine stores an exclusion as an xattr on the item itself, so a
        # read-only directory can never be excluded — tmutil fails with
        # "Error (-20)" / EINVAL. The common case is Go's module cache, which is
        # deliberately 0555. Check first: addexclusion costs ~11s even when it fails.
        if [[ ! -w "$path" ]]; then
            echo "! ${path}: read-only, cannot be excluded — skipping." >&2
            [[ -z "$ASIMOV_NO_WRITE_CACHE" ]] && append_state "$path" "$ASIMOV_FAILED_STATE"
            continue
        fi
        # tmutil prints its POSIXError dump to stdout, not stderr — silence both.
        if ! tmutil addexclusion "${path}" >/dev/null 2>&1; then
            echo "! ${path}: failed to exclude (tmutil error), skipping." >&2
            # Persist failure so we skip this path on subsequent runs.
            # Use --no-read-cache to retry.
            [[ -z "$ASIMOV_NO_WRITE_CACHE" ]] && append_state "$path" "$ASIMOV_FAILED_STATE"
            continue
        fi
        # Persist immediately — survives Ctrl+C so the next run doesn't redo this path
        [[ -z "$ASIMOV_NO_WRITE_CACHE" ]] && append_state "$path" "$ASIMOV_EXCLUDED_STATE"
        record_excluded_path "$path" "${path} has been excluded from Time Machine backups"
        verbose_timing "  [${tmutil_i}/${#to_exclude[@]}] excluded in $((SECONDS - path_start))s: ${path}"
    done
    if [[ $skipped_already -gt 0 ]]; then
        verbose_timing "Skipped ${skipped_already} already-excluded paths (Spotlight cache was stale)"
    fi
}

# Expand keep-only directory patterns and remember the paths that must survive
# normal dependency scans. Each pattern can match several directories.
prepare_keep_only() {
    ASIMOV_KEEP_ONLY_MATCHED_DIRS=()
    ASIMOV_KEEP_ONLY_MATCHED_RULES=()
    ASIMOV_KEEP_ONLY_PRESERVED_PATHS=()

    local rule pattern matched keep_i
    for ((rule = 0; rule < ${#ASIMOV_CONFIG_KEEP_ONLY_DIRS[@]}; rule++)); do
        pattern="${ASIMOV_CONFIG_KEEP_ONLY_DIRS[$rule]}"
        while IFS= read -r matched; do
            [[ -d "$matched" && ! -L "$matched" ]] || continue
            ASIMOV_KEEP_ONLY_MATCHED_DIRS+=("$matched")
            ASIMOV_KEEP_ONLY_MATCHED_RULES+=("$rule")
            for ((keep_i = 0; keep_i < ${#ASIMOV_CONFIG_KEEP_ONLY_KEEP_RULES[@]}; keep_i++)); do
                [[ "${ASIMOV_CONFIG_KEEP_ONLY_KEEP_RULES[$keep_i]}" == "$rule" ]] || continue
                ASIMOV_KEEP_ONLY_PRESERVED_PATHS+=("${matched}/${ASIMOV_CONFIG_KEEP_ONLY_KEEPS[$keep_i]}")
            done
        done < <(compgen -G "$pattern" || true)
    done
}

# Exclude every direct child that no matching keep-only rule names. All paths
# pass through the same cache, guard, dry-run, and output handling as other work.
exclude_keep_only_children() {
    [[ ${#ASIMOV_KEEP_ONLY_MATCHED_DIRS[@]} -gt 0 ]] || return 0

    [[ -z "$ASIMOV_QUIET" ]] && printf '\n%s%s%s\n' \
        "$ASIMOV_COLOR_INFO" '🧹 Excluding all but kept entries…' "$ASIMOV_COLOR_RESET"

    local dir child base keep_i rule_i configured_rule is_kept
    local nullglob_was_set=false dotglob_was_set=false
    local -a children=() direct_children=()
    if shopt -q nullglob; then nullglob_was_set=true; fi
    if shopt -q dotglob; then dotglob_was_set=true; fi
    shopt -s nullglob dotglob
    for ((rule_i = 0; rule_i < ${#ASIMOV_KEEP_ONLY_MATCHED_DIRS[@]}; rule_i++)); do
        dir="${ASIMOV_KEEP_ONLY_MATCHED_DIRS[$rule_i]}"
        direct_children=("${dir}"/*)
        for child in "${direct_children[@]}"; do
            [[ -e "$child" && ! -L "$child" ]] || continue
            base="${child##*/}"
            is_kept=false
            local matching_rule
            for ((matching_rule = 0; matching_rule < ${#ASIMOV_KEEP_ONLY_MATCHED_DIRS[@]}; matching_rule++)); do
                [[ "${ASIMOV_KEEP_ONLY_MATCHED_DIRS[$matching_rule]}" == "$dir" ]] || continue
                configured_rule="${ASIMOV_KEEP_ONLY_MATCHED_RULES[$matching_rule]}"
                for ((keep_i = 0; keep_i < ${#ASIMOV_CONFIG_KEEP_ONLY_KEEP_RULES[@]}; keep_i++)); do
                    if [[ "${ASIMOV_CONFIG_KEEP_ONLY_KEEP_RULES[$keep_i]}" == "$configured_rule" \
                        && "${ASIMOV_CONFIG_KEEP_ONLY_KEEPS[$keep_i]}" == "$base" ]]; then
                        is_kept=true
                        break
                    fi
                done
                [[ "$is_kept" == true ]] && break
            done
            [[ "$is_kept" == true ]] || children+=("$child")
        done
    done
    [[ "$nullglob_was_set" == true ]] || shopt -u nullglob
    [[ "$dotglob_was_set" == true ]] || shopt -u dotglob

    [[ ${#children[@]} -gt 0 ]] || return 0
    printf '%s\n' "${children[@]}" | sort -u | exclude_paths_from_stdin
}

# Feed a list of directories that exist to exclude_paths_from_stdin, under a
# heading. Used for the two fixed-directory passes at the end of a scan.
exclude_existing_dirs() {
    local heading="$1"
    shift
    [[ $# -gt 0 ]] || return 0

    [[ -z "$ASIMOV_QUIET" ]] && printf '\n%s%s%s\n' \
        "$ASIMOV_COLOR_INFO" "$heading" "$ASIMOV_COLOR_RESET"

    local dir
    for dir in "$@"; do
        if [[ -d "$dir" ]]; then
            echo "$dir"
        fi
    done | exclude_paths_from_stdin
}
