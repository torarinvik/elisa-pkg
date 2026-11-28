# Sourced by scripts/test.sh after the shared smoke setup.

# `agent` records one linked Elisa agent checkout in agent/runtime of the
# elisapkg home and hands every other command line to that checkout's
# interpreter. The fake interpreter below prints what it was given, so no
# Python is needed.
AGENT_HOME="$TEST_TMP/agent-home"
mkdir -m 700 "$AGENT_HOME"
AGENT_CHECKOUT="$TEST_TMP/fake-agent-checkout"
mkdir -p "$AGENT_CHECKOUT/.venv/bin" "$AGENT_CHECKOUT/src/nca"
: > "$AGENT_CHECKOUT/.venv/pyvenv.cfg"
: > "$AGENT_CHECKOUT/src/nca/agents.py"
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\nexit 9\n' > "$AGENT_CHECKOUT/.venv/bin/python"
chmod 755 "$AGENT_CHECKOUT/.venv/bin/python"

expect_agent_status() {
  local expected="$1"
  shift
  if ELISAPKG_HOME="$AGENT_HOME/.elisapkg" "$BIN" agent "$@" >"$TEST_TMP/agent.out" 2>&1; then
    actual=0
  else
    actual=$?
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "agent $* exited $actual, expected $expected:" >&2
    cat "$TEST_TMP/agent.out" >&2
    exit 1
  fi
}

expect_agent_status 0 --help
expect_agent_status 7 list
grep -F 'no agent runtime is linked' "$TEST_TMP/agent.out" >/dev/null
expect_agent_status 7 unlink
expect_agent_status 2 link
expect_agent_status 2 link "$TEST_TMP/no-such-checkout"
expect_agent_status 2 link "$TEST_TMP"
test ! -e "$AGENT_HOME/.elisapkg/agent/runtime"

expect_agent_status 0 link "$AGENT_CHECKOUT"
AGENT_RECORD="$AGENT_HOME/.elisapkg/agent/runtime"
test "$(stat -f '%Lp' "$AGENT_RECORD" 2>/dev/null || stat -c '%a' "$AGENT_RECORD")" = 600
grep -Fx "python=$(cd "$AGENT_CHECKOUT" && pwd -P)/.venv/bin/python" "$AGENT_RECORD" >/dev/null

# Every argument after `agent` reaches the runtime unchanged, output modes
# included, and the runtime's exit status is elisapkg's.
expect_agent_status 9 spawn demo --quiet -- host --color never
test "$(sed -n '1p' "$TEST_TMP/agent.out")" = -P
test "$(sed -n '2p' "$TEST_TMP/agent.out")" = -c
test "$(sed -n '4,$p' "$TEST_TMP/agent.out" | tr '\n' ' ')" = 'spawn demo --quiet -- host --color never '

# A malformed record or another user's write access fails closed.
cp "$AGENT_RECORD" "$TEST_TMP/agent-runtime.good"
printf 'elisapkg-agent-runtime=1\npython=relative/python\n' > "$AGENT_RECORD"
expect_agent_status 7 list
grep -F 'record is unreadable' "$TEST_TMP/agent.out" >/dev/null
cp "$TEST_TMP/agent-runtime.good" "$AGENT_RECORD"
chmod 770 "$AGENT_HOME/.elisapkg/agent"
expect_agent_status 5 list
expect_agent_status 5 link "$AGENT_CHECKOUT"
chmod 700 "$AGENT_HOME/.elisapkg/agent"

expect_agent_status 0 unlink
test ! -e "$AGENT_RECORD"
expect_agent_status 7 list
