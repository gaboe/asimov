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
  [[ "$(count_addexclusion_calls)" -gt 0 ]]
  : > "$ASIMOV_TEST_ADD_EXCLUSION_CALLS"

  run_asimov

  [[ "$status" -eq 0 ]]
  [[ "$(count_exclusions)" -eq "$first_count" ]]
  [[ "$(count_addexclusion_calls)" -eq 0 ]]
}

@test "full scan keeps an ancestor when it contains a kept child" {
  local project="${HOME}/Code/app"
  mkdir -p "$project/node_modules/memory" "$project/node_modules/log"
  touch "$project/package.json" "$project/node_modules/session.jsonl"
  write_config "[keep_only]
dir = ~/Code/app/node_modules
keep = memory"

  run_asimov

  [[ "$status" -eq 0 ]]
  refute_excluded "$project/node_modules"
  refute_excluded "$project/node_modules/memory"
  assert_excluded "$project/node_modules/log"
  assert_excluded "$project/node_modules/session.jsonl"
}

@test "cached scan keeps an ancestor and excludes its non-kept children" {
  local project="${HOME}/Code/app"
  mkdir -p "$project/node_modules/memory" "$project/node_modules/log"
  touch "$project/package.json" "$project/node_modules/session.jsonl"
  write_path_cache "$project/node_modules"
  write_config "[keep_only]
dir = ~/Code/app/node_modules
keep = memory"

  run_asimov

  [[ "$status" -eq 0 ]]
  refute_excluded "$project/node_modules"
  refute_excluded "$project/node_modules/memory"
  assert_excluded "$project/node_modules/log"
  assert_excluded "$project/node_modules/session.jsonl"
}

@test "fixed_dirs extra keeps an ancestor and excludes its non-kept children" {
  local cache="${HOME}/cache"
  mkdir -p "$cache/memory" "$cache/log"
  touch "$cache/session.jsonl"
  write_config "[fixed_dirs]
extra = ~/cache
[keep_only]
dir = ~/cache
keep = memory"

  run_asimov

  [[ "$status" -eq 0 ]]
  refute_excluded "$cache"
  refute_excluded "$cache/memory"
  assert_excluded "$cache/log"
  assert_excluded "$cache/session.jsonl"
}

@test "nested keep-only rules keep descendants and exclude their siblings" {
  local projects="${HOME}/projects"
  mkdir -p "$projects/settings" "$projects/a/memory" "$projects/a/settings"
  touch "$projects/a/log"
  write_config "[keep_only]
dir = ~/projects
keep = settings
dir = ~/projects/a
keep = memory"

  run_asimov

  [[ "$status" -eq 0 ]]
  refute_excluded "$projects/a"
  refute_excluded "$projects/a/memory"
  refute_excluded "$projects/settings"
  assert_excluded "$projects/a/log"
  assert_excluded "$projects/a/settings"
}

@test "equivalent keep-only directory spellings union their kept names" {
  local project="${HOME}/projects/a"
  mkdir -p "$project/memory" "$project/settings" "$project/transcripts"
  touch "$project/log"
  write_config "[keep_only]
dir = ~/projects/a/
keep = memory
dir = ~/projects/a//.
keep = settings
dir = ~/projects/a/.
keep = transcripts"

  run_asimov

  [[ "$status" -eq 0 ]]
  refute_excluded "$project/memory"
  refute_excluded "$project/settings"
  refute_excluded "$project/transcripts"
  assert_excluded "$project/log"
}

@test "newline child names are skipped without excluding their parent" {
  local project="${HOME}/projects/a"
  local newline_child="${project}/"$'\n'
  mkdir -p "$project/memory"
  touch "$project/log" "$newline_child"
  write_config "[keep_only]
dir = ~/projects/a
keep = memory"

  run_asimov

  [[ "$status" -eq 0 ]]
  refute_excluded "$project"
  refute_excluded "$project/memory"
  refute_excluded "${project}/"
  assert_excluded "$project/log"
}

@test "relative candidates preserve absolute keep-only paths" {
  local app="${HOME}/Code/app"
  local fixed="${HOME}/Code/fixed"
  mkdir -p "$app/node_modules/memory" "$fixed/memory"
  touch "$app/package.json" "$app/log" "$fixed/log"
  write_config "[fixed_dirs]
extra = Code/fixed
[keep_only]
dir = ~/Code/app
keep = node_modules
dir = ~/Code/fixed
keep = memory"

  cd "$HOME"
  run_asimov Code

  [[ "$status" -eq 0 ]]
  refute_excluded "Code/app/node_modules"
  refute_excluded "Code/fixed"
  assert_excluded "$app/log"
  assert_excluded "$fixed/log"
}

@test "newline matched directory does not exclude its parent siblings" {
  local project="${HOME}/projects/"$'\n'
  mkdir -p "$project/memory"
  touch "$project/log" "${HOME}/projects/unrelated.txt"
  write_config "[keep_only]
dir = ~/projects/*
keep = memory"

  run_asimov --quiet

  [[ "$status" -eq 0 ]]
  refute_excluded "${HOME}/projects/unrelated.txt"
}

@test "fixed_dirs extra still accepts a symlink to a directory" {
  local target="${HOME}/cache-target"
  local extra_link="${HOME}/cache-link"
  mkdir -p "$target"
  ln -s "$target" "$extra_link"
  write_config "[fixed_dirs]
extra = ~/cache-link"

  run_asimov

  [[ "$status" -eq 0 ]]
  assert_excluded "$extra_link"
}

@test "built-in fixed directories still accept a symlink to a directory" {
  local target="${HOME}/cache-target"
  local builtin_link="${HOME}/.npm/_cacache"
  mkdir -p "$target" "${HOME}/.npm"
  ln -s "$target" "$builtin_link"
  write_config "[fixed_dirs]
enabled = true"

  run_asimov

  [[ "$status" -eq 0 ]]
  assert_excluded "$builtin_link"
}

@test "cached paths still accept a symlink to a directory" {
  local target="${HOME}/cache-target"
  local project="${HOME}/Code/app"
  local cached_link="${project}/node_modules"
  mkdir -p "$target" "$project"
  ln -s "$target" "$cached_link"
  touch "$project/package.json"
  write_path_cache "$cached_link"
  write_config ""

  run_asimov

  [[ "$status" -eq 0 ]]
  assert_excluded "$cached_link"
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

@test "doctor accepts valid keep-only directory and basename keys" {
  write_config "[keep_only]
dir = ~/projects/*
keep = memory"

  run_asimov doctor

  [[ "$status" -eq 0 ]]
  [[ "$output" == *"${HOME}/.config/asimov/config looks valid"* ]]
}
