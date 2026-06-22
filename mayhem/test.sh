#!/usr/bin/env bash
#
# rabbitmq-c/mayhem/test.sh — PATCH-grade behavioral oracle.
#
# Asserts real AMQP URL-parsing behavior by running the pre-built
# oracle_parse_url program (built by build.sh) and grepping its stdout for
# known decoded field values.  A no-op / exit(0) PATCH produces NO output, so
# the grep fails — the suite cannot be trivially bypassed (SPEC §6.3).
#
# DO NOT compile here; build.sh already built every binary.  Fail loudly if
# the oracle is missing (it means build.sh didn't run, not a test failure).
#
# Emits a CTRF (ctrf.io) summary line and exits non-zero iff failed > 0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

ORACLE="/mayhem/oracle_parse_url"
CTRF_OUT="${CTRF_REPORT:-$SRC/ctrf-report.json}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "$CTRF_OUT" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$ORACLE" ]; then
  echo "ERROR: $ORACLE not found — run build.sh first" >&2
  emit_ctrf "rabbitmq-c-oracle" 0 1 0
  exit 2
fi

PASSED=0
FAILED=0

# Run the oracle and capture stdout.
OUT="$("$ORACLE" 2>&1)" ; ORC=$?
echo "$OUT"

# Anti-reward-hacking: grep for SPECIFIC decoded values the oracle must print.
# A neutered binary (LD_PRELOAD exit(0)) produces empty stdout — every grep
# fails, so FAILED > 0 and the suite fails.
run_check() {
  local label="$1" ; shift
  local pattern="$1" ; shift
  if printf '%s\n' "$OUT" | grep -qF "$pattern"; then
    echo "PASS $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "FAIL $label: expected '$pattern' in oracle output"
    FAILED=$(( FAILED + 1 ))
  fi
}

run_check "parse_url:user"         "parse_url user=myuser"
run_check "parse_url:password"     "parse_url password=mypass"
run_check "parse_url:host"         "parse_url host=broker.example.com"
run_check "parse_url:port"         "parse_url port=5673"
run_check "parse_url:vhost"        "parse_url vhost=myvhost"
run_check "parse_url:default_port" "default port=5672"
run_check "parse_url:default_vhost" "default vhost=/"
run_check "bad_url_rejected"       "bad_url_rc="
run_check "all_pass_marker"        "oracle_parse_url: ALL PASS"

# Also fail the suite if the oracle itself crashed.
if [ "$ORC" -ne 0 ]; then
  echo "FAIL oracle_parse_url exited $ORC (crash or assertion)"
  FAILED=$(( FAILED + 1 ))
fi

emit_ctrf "rabbitmq-c-oracle" "$PASSED" "$FAILED" 0
