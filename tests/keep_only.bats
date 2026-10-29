#!/usr/bin/env bats
#
# Behavioral tests for [keep_only] config.

load test_helper

@test "excludes non-kept files, folders, and dotfiles but keeps the named child" {
  local project="${HOME}/.claude/projects/session-a"
  mkdir -p "$project/memory" "$project/cache"
  ln -s "$project/cache" "$project/cache-link"
  printf '%s\n' data > "$project/transcript.jsonl"
  printf '%s\n' data > "$project/.hidden"
  write_config "[keep_only]
dir = ~/.claude/projects/*
keep = memory"

  run_asimov

  [[ "$status" -eq 0 ]]
  assert_excluded "$project/transcript.jsonl"
  assert_excluded "$project/cache"
  assert_excluded "$project/.hidden"
  refute_excluded "$project/memory"
  refute_excluded "$project/cache-link"
}

@test "each directory rule adds its own kept basenames" {
  local first="${HOME}/.claude/projects/session-a"
  local second="${HOME}/.claude/projects/special"
  mkdir -p "$first/memory" "$second/memory" "$second/transcripts"
  touch "$first/transcript.jsonl" "$second/transcript.jsonl" "$second/session.jsonl"
  write_config "[keep_only]
dir = ~/.claude/projects/*
keep = memory
dir = ~/.claude/projects/special
keep = transcripts"

  run_asimov

  [[ "$status" -eq 0 ]]
  assert_excluded "$first/transcript.jsonl"
  assert_excluded "$second/session.jsonl"
  refute_excluded "$first/memory"
  refute_excluded "$second/memory"
  refute_excluded "$second/transcripts"
}

@test "kept directories and their contents stay available to Time Machine" {
  local project="${HOME}/.claude/projects/session-a"
  mkdir -p "$project/memory/node_modules"
  printf '%s\n' sentinel > "$project/memory/package.json"
  write_config "[keep_only]
dir = ~/.claude/projects/*
keep = memory"

  run_asimov

  [[ "$status" -eq 0 ]]
  refute_excluded "$project/memory"
  refute_excluded "$project/memory/node_modules"
}

@test "glob pattern applies to two parent directories" {
  local first="${HOME}/.claude/projects/session-a"
  local second="${HOME}/.claude/projects/session-b"
  mkdir -p "$first/memory" "$second/memory"
  touch "$first/transcript.jsonl" "$second/transcript.jsonl"
  write_config "[keep_only]
dir = ~/.claude/projects/*
keep = memory"

  run_asimov

  [[ "$status" -eq 0 ]]
  assert_excluded "$first/transcript.jsonl"
  assert_excluded "$second/transcript.jsonl"
  refute_excluded "$first/memory"
  refute_excluded "$second/memory"
}

@test "an unmatched directory pattern is not an error" {
  write_config "[keep_only]
dir = ~/does-not-exist/*
keep = memory"

  run_asimov

  [[ "$status" -eq 0 ]]
  [[ "$(count_exclusions)" -eq 0 ]]
}

@test "dry run previews children without recording exclusions" {
  local project="${HOME}/.claude/projects/session-a"
  mkdir -p "$project/memory"
  touch "$project/transcript.jsonl"
  write_config "[keep_only]
dir = ~/.claude/projects/*
keep = memory"

  run_asimov --dry-run

  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Would exclude: ${project}/transcript.jsonl"* ]]
  [[ "$(count_exclusions)" -eq 0 ]]
}

@test "a second run adds no exclusions for existing children" {
  local project="${HOME}/.claude/projects/session-a"
  mkdir -p "$project/memory" "$project/cache"
  touch "$project/transcript.jsonl"
  write_config "[keep_only]
dir = ~/.claude/projects/*
keep = memory"

  run_asimov
  [[ "$status" -eq 0 ]]
  local first_count
  first_count="$(count_exclusions)"
  [[ "$first_count" -eq 2 ]]

  run_asimov

  [[ "$status" -eq 0 ]]
  [[ "$(count_exclusions)" -eq "$first_count" ]]
}

@test "doctor reports keep before dir" {
  write_config "[keep_only]
keep = memory
dir = ~/projects/*"

  run_asimov doctor

  [[ "$status" -eq 1 ]]
  [[ "$output" == *"keep_only:keep must follow a keep_only:dir"* ]]
}

@test "doctor reports a kept value with a slash" {
  write_config "[keep_only]
dir = ~/projects/*
keep = memory/extra"

  run_asimov doctor

  [[ "$status" -eq 1 ]]
  [[ "$output" == *"keep_only:keep must be a basename"* ]]
}
