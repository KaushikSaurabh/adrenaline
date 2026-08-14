#!/usr/bin/env bash
# Credential-shape coverage for the watchdog secret gate, plus bash/PowerShell
# pattern-list parity (the two watchdogs must refuse the same things).
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/lib/assert.sh"
. "$DIR/lib/fixtures.sh"

setup(){ new_store; }
teardown(){ cleanup_store; }

# Asserts the scan rejects $1 and (with $2 = "clean") that a near-miss passes.
assert_rejected(){ # sample
  write_file leak.md "prefix $1 suffix"
  run_watchdog
  assert_status 2 "$STATUS" "scan should reject '$1'"
}

assert_accepted(){ # sample
  write_file note.md "prefix $1 suffix"
  run_watchdog
  assert_status 0 "$STATUS" "scan should accept '$1'"
}

test_rejects_github_fine_grained_pat(){ assert_rejected "github_pat_11ABCDEFG0abcdefghijkl_MNOPQRSTUVWXYZ"; }
test_rejects_github_classic_token(){ assert_rejected "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"; }
test_rejects_github_oauth_token(){ assert_rejected "gho_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"; }
test_rejects_gitlab_pat(){ assert_rejected "glpat-ABCDEFGHIJKLMNOPQRST"; }
test_rejects_openai_style_key(){ assert_rejected "sk-ABCDEFGHIJKLMNOPQRSTUVWX"; }
test_rejects_stripe_live_key(){ assert_rejected "sk_live_ABCDEFGHIJKLMNOP"; }
test_rejects_stripe_test_key(){ assert_rejected "sk_test_ABCDEFGHIJKLMNOP"; }
test_rejects_aws_access_key_id(){ assert_rejected "AKIAIOSFODNN7EXAMPLE"; }
test_rejects_google_api_key(){ assert_rejected "AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456"; }
test_rejects_google_oauth_client_secret(){ assert_rejected "GOCSPX-ABCDEFGHIJKLMNOPQRSTU"; }
test_rejects_slack_bot_token(){ assert_rejected "xoxb-1234567890-ABCDEFGHIJ"; }
test_rejects_slack_app_token(){ assert_rejected "xapp-1-ABCDEFGHIJKL"; }
test_rejects_jwt(){ assert_rejected "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"; }
test_rejects_private_key_header(){ assert_rejected "-----BEGIN RSA PRIVATE KEY-----"; }
test_rejects_unlabelled_private_key_header(){ assert_rejected "-----BEGIN PRIVATE KEY-----"; }

test_accepts_prose_mentioning_credentials(){
  assert_accepted "rotate the AKIA key in the console; the sk- prefix means OpenAI"
}
test_accepts_short_lookalikes(){ assert_accepted "ghp_tooshort AKIA123 glpat-short sk_live_short"; }
test_accepts_public_key_header(){ assert_accepted "-----BEGIN PUBLIC KEY-----"; }

# --- cross-platform parity ---------------------------------------------------

# Extracts the pattern alternatives from each watchdog, normalised so the two
# dialects (bash ERE vs PowerShell regex escaping of '.') compare equal.

# Splits on top-level '|' only, so alternations like sk_(live|test) stay intact.
split_alternatives(){
  awk '{
    depth = 0; item = ""
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "(") depth++
      else if (c == ")") depth--
      if (c == "|" && depth == 0) { print item; item = "" } else item = item c
    }
    print item
  }'
}

bash_patterns(){
  grep -m1 "^PATTERNS=" "$WATCHDOG_SH" \
    | sed -e "s/^PATTERNS='//" -e "s/'$//" \
    | split_alternatives | sed 's/\[[.]\]/./g' | sort
}

ps1_patterns(){
  grep -m1 '^\$secretPatterns' "$WATCHDOG_PS1" | tr -d '\r' \
    | sed -e 's/^[^(]*(//' -e 's/)$//' \
    | sed "s/','/\n/g" | sed -e "s/^'//" -e "s/'$//" -e 's/\\[.]/./g' | sort
}

test_bash_and_powershell_patterns_match(){
  local diff_out
  diff_out=$(diff <(bash_patterns) <(ps1_patterns)) || \
    fail "bash and PowerShell secret patterns diverge:
$diff_out"
}

test_pattern_list_is_non_trivial(){
  local n
  n=$(bash_patterns | grep -c .)
  [ "$n" -ge 12 ] || fail "expected >= 12 secret patterns, found $n"
}

run_tests
