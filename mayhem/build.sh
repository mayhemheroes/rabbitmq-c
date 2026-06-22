#!/usr/bin/env bash
#
# rabbitmq-c/mayhem/build.sh — build alanxz/rabbitmq-c's three OSS-Fuzz harnesses as sanitized
# libFuzzer targets (+ standalone run-once reproducers).
#
# The fuzzed surface is rabbitmq-c's AMQP WIRE-PROTOCOL parsing on attacker-controlled bytes:
#   fuzz_url    — amqp_parse_url(): parses an AMQP connection URI ("amqp[s]://user:pass@host:port/vhost").
#   fuzz_table  — amqp_decode_table(): decodes an AMQP field-table from raw wire bytes (the <type-tag>
#                 + length-prefixed encoding); recurses into nested tables/arrays.
#   fuzz_server — stands up a throwaway localhost TCP "broker", feeds the input as the broker's
#                 response, then drives amqp_login()/amqp_handle_input() so the client parses those
#                 bytes as AMQP frames (method/header/body/heartbeat) + Connection.* methods.
#
# We build the rabbitmq-c library ITSELF with $SANITIZER_FLAGS (via CMake -DBUILD_OSSFUZZ=ON, the same
# path OSS-Fuzz uses) so the parser code — not just the harness — is instrumented. SSL is disabled
# (-DENABLE_SSL_SUPPORT=OFF): none of the fuzzers nor the self-contained unit tests use TLS, so we
# drop the OpenSSL build dependency.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF ≤ 3 required by Mayhem's triage (clang-19 defaults to DWARF-5 with plain -g).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# ── 1) Configure + build with CMake exactly like OSS-Fuzz (BUILD_OSSFUZZ=ON), but inject the org
#       sanitizer flags into the C compile + link so the library AND the harnesses are instrumented. ──
# We also add -fsanitize=fuzzer-no-link to the COMPILE flags so SanitizerCoverage is emitted into the
# rabbitmq-c library + harness objects — without it the libFuzzer engine has no coverage feedback on
# the parser (the link-time -fsanitize=fuzzer alone does not instrument already-compiled TUs). The
# standalone reproducers below deliberately omit this (they have no fuzzer runtime).
BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"

FUZZ_COMPILE_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
case "$LIB_FUZZING_ENGINE" in
  *fuzzer*) FUZZ_COMPILE_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" ;;
esac

cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DBUILD_OSSFUZZ=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DENABLE_SSL_SUPPORT=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TOOLS=OFF \
    -DBUILD_TESTING=OFF \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$FUZZ_COMPILE_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    -DLIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE"

cmake --build "$BUILD" -j"$MAYHEM_JOBS"

# CMake puts the harness ELFs under <build>/fuzz/. Copy each to /mayhem/<name>.
for harness in fuzz_url fuzz_table fuzz_server; do
  cp "$BUILD/fuzz/$harness" "/mayhem/$harness"
  echo "built $harness (libFuzzer)"
done

# ── 2) Standalone run-once reproducers: link each harness object against the CMake-built static
#       library + our own main() (no libFuzzer runtime). Find the static archive CMake produced. ──
LIBA="$(find "$BUILD" -name 'librabbitmq*.a' | head -1)"
if [ -z "$LIBA" ]; then
  echo "WARNING: could not find static librabbitmq archive — skipping standalone reproducers" >&2
else
  # CMake generates two headers into the build tree: config.h (-> <build>/librabbitmq/) and the
  # export macros (-> <build>/include/rabbitmq-c/export.h). Both must precede the source include dir.
  INC="-I$BUILD/include -I$SRC/include -I$BUILD/librabbitmq -I$SRC/librabbitmq"
  DEFS="-DHAVE_CONFIG_H -DAMQP_STATIC"
  # The standalone driver: STANDALONE_FUZZ_MAIN (a .o/.c the base may provide) else our own main.
  if [ -n "$STANDALONE_FUZZ_MAIN" ] && [ -e "$STANDALONE_FUZZ_MAIN" ]; then
    MAIN_SRC="$STANDALONE_FUZZ_MAIN"
  else
    MAIN_SRC="$HARNESS_DIR/standalone_main.c"
  fi
  for harness in fuzz_url fuzz_table fuzz_server; do
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC $DEFS \
        "$SRC/fuzz/$harness.c" "$MAIN_SRC" "$LIBA" -lpthread \
        -o "/mayhem/$harness-standalone"
    echo "built $harness-standalone"
  done

  # ── 3) Behavioral oracle: parse a known AMQP URL and PRINT decoded fields.
  #       test.sh greps for known field values — a neutered exit(0) produces no
  #       output and the grep fails (SPEC §6.3 anti-reward-hacking gate). ──
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC $DEFS \
      "$HARNESS_DIR/oracle_parse_url.c" "$LIBA" -lpthread \
      -o "/mayhem/oracle_parse_url"
  echo "built oracle_parse_url"
fi

echo "build.sh complete:"
ls -la /mayhem/fuzz_url /mayhem/fuzz_table /mayhem/fuzz_server \
       /mayhem/fuzz_url-standalone /mayhem/fuzz_table-standalone /mayhem/fuzz_server-standalone \
       /mayhem/oracle_parse_url 2>&1 || true
