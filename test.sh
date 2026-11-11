#!/usr/bin/env bash
# Tests the launchers against a fake `podman` that records its argv, one argument per
# line, so nothing is built or run for real; and pclaude's macOS credential sync against
# a fake Keychain, so the real one is never touched.
#
# Test names pick what they run against:
#   test_both_*      once per launcher, as $L (prefix $P)
#   test_pclaude_*   pclaude only;  test_pcodex_*  pcodex only
#   test_keychain_*  pclaude's sync functions; macOS only (they use the real plutil)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
# Stand-in for `podman`: `image exists` answers from $FAKE_NO_IMAGE, everything else is
# appended to $FAKE_LOG as one call per block, and exits with $FAKE_STATUS.
cat >"$tmp/bin/podman" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "image exists" ]; then [ -z "${FAKE_NO_IMAGE:-}" ]; exit; fi
{ printf '%s\n' "$@"; echo "--"; } >>"$FAKE_LOG"
exit "${FAKE_STATUS:-0}"
EOF
# Stand-in for `security`: one item, stored in $FAKE_KEYCHAIN. It only answers the exact
# calls pclaude should make, so targeting the wrong item or account fails the tests.
cat >"$tmp/bin/security" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_LOCKED:-}" ] || exit 51
case "$1" in
  find-generic-password)
    [ "$*" = "find-generic-password -s Claude Code-credentials -a tester -w" ] || exit 44
    [ -f "$FAKE_KEYCHAIN" ] || exit 44
    cat "$FAKE_KEYCHAIN"; echo ;;
  -i)
    read -r cmd; echo "$cmd" >>"$FAKE_KEYCHAIN.log"
    prefix="add-generic-password -U -s \"Claude Code-credentials\" -a \"tester\" -X "
    case "$cmd" in "$prefix"*) ;; *) exit 0 ;; esac   # the real one may also exit 0 here
    hex="${cmd#"$prefix"}"; printf "$(printf %s "$hex" | sed 's/../\\x&/g')" >"$FAKE_KEYCHAIN" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/bin/podman" "$tmp/bin/security"

export PATH="$tmp/bin:$PATH" HOME="$tmp/home" USER=tester \
       FAKE_LOG="$tmp/log" FAKE_KEYCHAIN="$tmp/keychain" \
       PCLAUDE_RELABEL=off PCODEX_RELABEL=off
for p in PCLAUDE PCODEX; do
  unset "${p}_IMAGE" "${p}_HOME" "${p}_ARGS" "${p}_NO_YOLO" "${p}_ALLOW_HOME"
done
unset XDG_DATA_HOME GH_TOKEN TERM COLORTERM \
      ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL \
      CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
      OPENAI_API_KEY OPENAI_BASE_URL CODEX_API_KEY CODEX_ACCESS_TOKEN

# For the keychain tests: loads sync_credentials and friends, nothing else.
# shellcheck source=pclaude
source "$root/pclaude"
set +e

share="$HOME/.local/share/yolopod"
run() { status=0; "$root/$L" "$@" >"$tmp/stdout" 2>"$tmp/stderr" || status=$?; }
eq() { [ "$1" = "$2" ] || { printf '  expected: %s\n  got:      %s\n' "$2" "$1"; exit 1; }; }
stderr_has() { grep -q -- "$1" "$tmp/stderr" || { echo "  stderr lacks: $1"; cat "$tmp/stderr"; exit 1; }; }
# Fails unless these arguments appear consecutively in the log, e.g. `seq_in_log --volume "$a:$b"`.
seq_in_log() {
  local want; want="$(printf '\037%s' "$@")"$'\037'
  { printf '\037'; tr '\n' '\037' <"$FAKE_LOG"; } | grep -qF -- "$want" || { echo "  log lacks: $*"; exit 1; }
}
not_forwarded() { ! grep -q "^$1=" "$FAKE_LOG" || { echo "  forwarded: $1"; exit 1; }; }
# Everything after the image name in the (last) run call.
cmd() { sed -n '/^localhost\/yolopod$/,/^--$/p' "$FAKE_LOG" | sed '1d;$d' | paste -sd' ' -; }
# Every --volume value, in order.
volumes() { awk 'prev == "--volume" { print } { prev = $0 }' "$FAKE_LOG" | paste -sd' ' -; }
calls() { paste -sd' ' - <"$FAKE_LOG"; }
no_calls() { [ ! -e "$FAKE_LOG" ] || { echo "  podman was called"; exit 1; }; }

# A login whose access token and expiry are the given ones.
creds() { printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r","expiresAt":%s}}' "$1" "$2"; }
keychain() { printf '%s' "$1" >"$FAKE_KEYCHAIN"; }
file() { printf '%s' "$1" >"$CREDS"; }
run_sync() { status=0; sync_credentials 2>"$tmp/stderr" || status=$?; }
mode() { stat -f %Lp "$1"; }
no_keychain_writes() { [ ! -e "$FAKE_KEYCHAIN.log" ] || { echo "  unexpected Keychain write"; exit 1; }; }

# --- Both launchers ----------------------------------------------------------------------

test_both_share_one_image_and_share_dir() {
  run --$L-build
  eq "$status" 0; eq "$(calls)" "build -t localhost/yolopod $share --"
}
test_both_build_passes_extra_args() {
  run --$L-build --build-arg CODEX_VERSION=1.2.3
  eq "$(calls)" "build -t localhost/yolopod --build-arg CODEX_VERSION=1.2.3 $share --"
}
test_both_update_rebuilds_from_scratch() {
  run --$L-update
  eq "$(calls)" "build -t localhost/yolopod --pull --no-cache $share --"
}
test_both_custom_image_and_home() {
  mkdir -p "$tmp/share" && cp "$root/lib.sh" "$tmp/share/" && touch "$tmp/share/Containerfile"
  export "${P}_IMAGE=localhost/other" "${P}_HOME=$tmp/share"
  run --$L-build
  eq "$(calls)" "build -t localhost/other $tmp/share --"
}
test_both_missing_image_is_built_first() {
  FAKE_NO_IMAGE=1 run
  eq "$status" 0
  seq_in_log build -t localhost/yolopod "$share" -- run
}
test_both_missing_containerfile_fails_clearly() {
  rm "$share/Containerfile"; FAKE_NO_IMAGE=1 run
  eq "$status" 1; stderr_has "no Containerfile in"; no_calls
}
test_both_missing_lib_fails_clearly() {
  rm "$share/lib.sh"; run
  eq "$status" 1; stderr_has "$L: no lib.sh in $share"; no_calls
}
test_both_container_is_hardened() {
  run; seq_in_log --cap-drop all --security-opt no-new-privileges
  : >"$FAKE_LOG"; run --$L-shell; seq_in_log --cap-drop all --security-opt no-new-privileges
}
test_both_hostname_is_the_launcher() {
  run; seq_in_log --hostname "$L"
}
test_both_shell_runs_bash_without_harness_flags() {
  run --$L-shell -c "ls"
  eq "$(cmd)" "bash -c ls"
}
test_both_launcher_option_after_harness_args_goes_through() {
  run x --$L-shell
  # ${L#p} is the harness binary: claude, codex.
  case "$(cmd)" in "${L#p} "*" x --$L-shell") ;; *) echo "  got: $(cmd)"; exit 1 ;; esac
}
test_both_other_launcher_options_are_not_ours() {
  local other; [ "$L" = pclaude ] && other=pcodex || other=pclaude
  run --$other-build
  case "$(cmd)" in "${L#p} "*" --$other-build") ;; *) echo "  got: $(cmd)"; exit 1 ;; esac
}
test_both_project_mounted_at_its_own_path() {
  run
  seq_in_log --volume "$PWD:$PWD" --workdir "$PWD"
}
test_both_gitconfig_mounted_read_only_when_present() {
  touch "$HOME/.gitconfig"; run
  seq_in_log --volume "$HOME/.gitconfig:/home/node/.gitconfig:ro"
}
test_both_relabel_suffixes() {
  touch "$HOME/.gitconfig"; export "${P}_RELABEL=Z"; run
  seq_in_log --volume "$PWD:$PWD:Z"
  seq_in_log --volume "$HOME/.gitconfig:/home/node/.gitconfig:ro,Z"
}
test_both_relabel_is_read_from_own_prefix_only() {
  local other; [ "$P" = PCLAUDE ] && other=PCODEX || other=PCLAUDE
  export "${other}_RELABEL=Z"; run
  seq_in_log --volume "$PWD:$PWD" --workdir
}
test_both_bad_relabel_is_refused() {
  export "${P}_RELABEL=yes"; run
  eq "$status" 1; stderr_has "${P}_RELABEL must be"; no_calls
}
test_both_common_env_forwarded_only_when_set() {
  GH_TOKEN="" TERM=xterm-256color run
  seq_in_log --env TERM=xterm-256color
  not_forwarded GH_TOKEN; not_forwarded COLORTERM
}
test_both_extra_podman_args_come_before_image() {
  export "${P}_ARGS=-e FOO=bar  -v /a:/b"; run x
  seq_in_log -e FOO=bar -v /a:/b localhost/yolopod
}
test_both_refuses_home() {
  cd "$HOME" && run
  eq "$status" 1; stderr_has "set ${P}_ALLOW_HOME=1"; no_calls
}
test_both_home_allowed_on_request() {
  cd "$HOME" && export "${P}_ALLOW_HOME=1" && run
  eq "$status" 0; seq_in_log --volume "$HOME:$HOME"
}
test_both_refuses_root() {
  cd / && run
  eq "$status" 1; no_calls
}
test_both_exit_status_propagates() {
  FAKE_STATUS=7 run
  eq "$status" 7
}
test_both_help_prints_usage_only() {
  run --$L-help
  eq "$status" 0; no_calls
  grep -q "^Usage: $L" "$tmp/stdout" && grep -q "${P}_NO_YOLO" "$tmp/stdout" \
    && grep -q "${P}_ALLOW_HOME" "$tmp/stdout" || { cat "$tmp/stdout"; exit 1; }
}

# --- pclaude -----------------------------------------------------------------------------

test_pclaude_runs_claude_yolo_with_args_untouched() {
  run -p "two words" '$HOME' --model opus
  eq "$(cmd)" 'claude --dangerously-skip-permissions -p two words $HOME --model opus'
  seq_in_log claude --dangerously-skip-permissions -p "two words" '$HOME' --model opus
}
test_pclaude_no_yolo_drops_skip_permissions() {
  PCLAUDE_NO_YOLO=1 run --resume
  eq "$(cmd)" "claude --resume"
}
test_pclaude_no_yolo_other_than_1_stays_yolo() {
  PCLAUDE_NO_YOLO=0 run
  eq "$(cmd)" "claude --dangerously-skip-permissions"
}
test_pclaude_mounts_only_claude_config() {
  PCLAUDE_RELABEL=Z run
  eq "$(volumes)" "$PWD:$PWD:Z $HOME/.claude:/home/node/.claude:Z $HOME/.claude.json:/home/node/.claude.json:Z"
  [ -d "$HOME/.claude" ] || { echo "  ~/.claude not created"; exit 1; }
  eq "$(cat "$HOME/.claude.json")" "{}"
  [ ! -e "$HOME/.codex" ] || { echo "  ~/.codex created"; exit 1; }
}
test_pclaude_keeps_existing_claude_json() {
  echo '{"x":1}' >"$HOME/.claude.json"; run
  eq "$(cat "$HOME/.claude.json")" '{"x":1}'
}
test_pclaude_forwards_only_anthropic_env() {
  ANTHROPIC_API_KEY="sk with space" CLAUDE_CODE_USE_BEDROCK=1 OPENAI_API_KEY=leak CODEX_API_KEY=leak run
  seq_in_log --env "ANTHROPIC_API_KEY=sk with space"
  seq_in_log --env CLAUDE_CODE_USE_BEDROCK=1
  not_forwarded OPENAI_API_KEY; not_forwarded CODEX_API_KEY
}

# --- pcodex ------------------------------------------------------------------------------

test_pcodex_runs_codex_yolo_with_args_untouched() {
  run exec "two words" '$HOME' --model o3
  eq "$(cmd)" 'codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox exec two words $HOME --model o3'
  seq_in_log codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox exec "two words" '$HOME' --model o3
}
test_pcodex_no_yolo_restores_approvals_but_not_inner_sandbox() {
  PCODEX_NO_YOLO=1 run resume
  eq "$(cmd)" "codex --no-alt-screen --sandbox danger-full-access --ask-for-approval on-request resume"
}
test_pcodex_no_yolo_other_than_1_stays_yolo() {
  PCODEX_NO_YOLO=0 run
  eq "$(cmd)" "codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox"
}
test_pcodex_mounts_only_codex_config() {
  PCODEX_RELABEL=Z run
  eq "$(volumes)" "$PWD:$PWD:Z $HOME/.codex:/home/node/.codex:Z"
  [ -d "$HOME/.codex" ] || { echo "  ~/.codex not created"; exit 1; }
  [ ! -e "$HOME/.claude" ] && [ ! -e "$HOME/.claude.json" ] || { echo "  claude config created"; exit 1; }
}
test_pcodex_forwards_only_openai_env() {
  OPENAI_API_KEY="sk with space" CODEX_ACCESS_TOKEN=t ANTHROPIC_API_KEY=leak run
  seq_in_log --env "OPENAI_API_KEY=sk with space"
  seq_in_log --env CODEX_ACCESS_TOKEN=t
  not_forwarded ANTHROPIC_API_KEY
}

# --- pclaude's macOS Keychain sync -------------------------------------------------------

test_keychain_newer_overwrites_file() {
  keychain "$(creds new 200)"; file "$(creds old 100)"; run_sync
  eq "$status" 0; eq "$(cat "$CREDS")" "$(creds new 200)"; eq "$(mode "$CREDS")" 600; no_keychain_writes
}
test_keychain_file_newer_goes_back_to_keychain() {
  keychain "$(creds old 100)"; file "$(creds new 200)"; run_sync
  eq "$status" 0; eq "$(cat "$FAKE_KEYCHAIN")" "$(creds new 200)"; eq "$(cat "$CREDS")" "$(creds new 200)"
  eq "$(cat "$tmp/stderr")" ""
}
test_keychain_equal_touches_nothing() {
  keychain "$(creds same 100)"; file "$(creds same 100)"; chmod 644 "$CREDS"; run_sync
  eq "$status" 0; eq "$(mode "$CREDS")" 644; no_keychain_writes
}
test_keychain_file_is_created_private_despite_umask() {
  umask 022; keychain "$(creds new 200)"; run_sync
  eq "$status" 0; eq "$(mode "$CREDS")" 600; eq "$(ls -A "$HOME/.claude")" .credentials.json
}
test_keychain_world_readable_file_is_replaced_private() {
  keychain "$(creds new 200)"; file "$(creds old 100)"; chmod 644 "$CREDS"; run_sync
  eq "$(mode "$CREDS")" 600
}
test_keychain_only_file_restores_keychain() {
  file "$(creds only 100)"; run_sync
  eq "$status" 0; eq "$(cat "$FAKE_KEYCHAIN")" "$(creds only 100)"
}
test_keychain_neither_is_not_logged_in() {
  run_sync
  eq "$status" 1; no_keychain_writes; [ ! -e "$CREDS" ] || { echo "  file created"; exit 1; }
}
test_keychain_garbage_file_loses() {
  keychain "$(creds good 1)"; file "not json"; run_sync
  eq "$status" 0; eq "$(cat "$CREDS")" "$(creds good 1)"
}
test_keychain_garbage_keychain_loses() {
  keychain "not json"; file "$(creds good 1)"; run_sync
  eq "$status" 0; eq "$(cat "$FAKE_KEYCHAIN")" "$(creds good 1)"
}
test_keychain_file_without_refresh_token_never_reaches_keychain() {
  file '{"claudeAiOauth":{"accessToken":"a","expiresAt":9999999999999}}'; run_sync
  eq "$status" 1; no_keychain_writes
}
test_keychain_non_numeric_expiry_is_not_a_login() {
  file '{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":"soon"}}'; run_sync
  eq "$status" 1; no_keychain_writes
}
test_keychain_awkward_token_survives_round_trip() {
  local nasty='a b \"q\" '\''s $(x) `y` %s %% \\ é 🔑'
  file "$(creds "$nasty" 200)"; run_sync
  eq "$(cat "$FAKE_KEYCHAIN")" "$(creds "$nasty" 200)"
  rm "$CREDS"; run_sync
  eq "$(cat "$CREDS")" "$(creds "$nasty" 200)"
}
test_keychain_failed_write_warns_and_keeps_file() {
  file "$(creds new 200)"; FAKE_LOCKED=1 run_sync
  eq "$status" 0; eq "$(cat "$CREDS")" "$(creds new 200)"
  stderr_has "could not update the Keychain"
}
test_keychain_launcher_dies_when_not_logged_in() {
  rm -f "$FAKE_KEYCHAIN"; L=pclaude run
  eq "$status" 1; stderr_has "not logged in"; no_calls
}
test_keychain_launcher_syncs_back_after_the_container() {
  # The fake podman plays a container that refreshed the token in the mounted file.
  cat >"$tmp/bin/podman" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "image exists" ]; then exit 0; fi
printf '%s' '$(creds refreshed 300)' >"$CREDS"
EOF
  keychain "$(creds old 100)"; L=pclaude run
  eq "$status" 0; eq "$(cat "$FAKE_KEYCHAIN")" "$(creds refreshed 300)"
}

# --- Runner ------------------------------------------------------------------------------

reset() {
  rm -rf "$HOME" "$FAKE_LOG" "$FAKE_KEYCHAIN" "$FAKE_KEYCHAIN.log" "$tmp/project" "$tmp/share"
  printf '%s\n' "$podman_fake" >"$tmp/bin/podman"   # one test swaps it out
  mkdir -p "$share" "$tmp/project"
  cp "$root/lib.sh" "$share/lib.sh"; touch "$share/Containerfile"
  # On macOS pclaude syncs before launching; give it a login so it gets that far.
  keychain "$(creds seeded 100)"
}

podman_fake="$(cat "$tmp/bin/podman")"
failed=0
for t in $(declare -F | awk '/ test_/ {print $3}'); do
  case "$t" in
    test_both_*)     launchers=(pclaude pcodex) ;;
    test_pclaude_*)  launchers=(pclaude) ;;
    test_pcodex_*)   launchers=(pcodex) ;;
    test_keychain_*)
      if [ "$(uname -s)" != Darwin ]; then echo "skip ${t#test_} (macOS only)"; continue; fi
      launchers=(-) ;;
  esac
  for L in "${launchers[@]}"; do
    reset
    case "$t" in test_keychain_*) rm -f "$FAKE_KEYCHAIN"; mkdir -p "$HOME/.claude" ;; esac
    P="$(printf '%s' "$L" | tr '[:lower:]' '[:upper:]')"
    ( set -e; cd "$tmp/project"; "$t" )
    if [ $? = 0 ]; then r=ok; else r=FAIL; failed=1; fi
    printf '%-4s %s%s\n' "$r" "${t#test_}" "${launchers[1]:+ [$L]}"
  done
done
exit "$failed"
