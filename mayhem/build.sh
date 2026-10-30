#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# The mDNS fuzzers (fuzz_mdns_*) need the deps/mdnsd submodule (mayhem.yml's checkout fetches it).
# Without it CMake silently drops them, so fail loudly instead of shipping fewer targets.
[ -f deps/mdnsd/libmdnsd/mdnsd.c ] || { echo "deps/mdnsd submodule missing (git submodule update --init deps/mdnsd)" >&2; exit 1; }

FUZZERS="fuzz_server_services fuzz_process_request fuzz_client fuzz_pubsub_connection_config
 fuzz_binary_message fuzz_opn_message fuzz_msg_message fuzz_tcp_message fuzz_binary_decode
 fuzz_datatype_description fuzz_src_ua_util fuzz_attributeoperand fuzz_parse_string
 fuzz_mdns_message fuzz_mdns_xht fuzz_base64_encode fuzz_base64_decode fuzz_json_decode
 fuzz_json_decode_encode fuzz_config_json fuzz_pubsub_json fuzz_pubsub_binary
 fuzz_certificate_parse fuzz_xml_decode_encode fuzz_eventfilter_parse"

# Same library configuration as OSS-Fuzz's projects/open62541/build.sh (OpenSSL, no amalgamation, no
# logging; OSS-Fuzz also defines FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION, which the harnesses need), driven through upstream's own UA_BUILD_OSS_FUZZ switch: the engine comes from
# $LIB_FUZZING_ENGINE and the binaries land in $OUT. Fuzzers link the library's object files, so one
# CMake build instruments both the library and the harnesses.
configure_and_build() {  # <build-dir> <extra C/C++ flags> <engine link items, ';'-separated>
  local dir="$1" extra="-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION $2" engine="$3"
  OUT="$SRC/$dir/out" LIB_FUZZING_ENGINE="$engine" cmake -S "$SRC" -B "$SRC/$dir" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $extra" \
    -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $extra" \
    -DCMAKE_C_FLAGS_DEBUG="$DEBUG_FLAGS" -DCMAKE_CXX_FLAGS_DEBUG="$DEBUG_FLAGS" \
    -DUA_ENABLE_AMALGAMATION=OFF -DBUILD_SHARED_LIBS=OFF -DUA_BUILD_EXAMPLES=OFF \
    -DUA_LOGLEVEL=600 -DUA_ENABLE_ENCRYPTION=OPENSSL -DUA_BUILD_OSS_FUZZ=ON
  cmake --build "$SRC/$dir" -j"$MAYHEM_JOBS" --target $FUZZERS
}

# LeakSanitizer off at build time (SPEC §6.2 item 15), linked into every binary.
# Always configure from scratch: re-running cmake over an old cache (compiler path differs under
# ccache) drops the -D switches during the project() pass and the fuzz targets vanish (idempotence, §6.2 item 9).
rm -rf build-fuzz build-standalone build-tests
mkdir -p build-fuzz build-standalone
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build-fuzz/lsan_off.o
cp build-fuzz/lsan_off.o build-standalone/lsan_off.o

# Upstream's fuzz_mdns_message.cc has its parse check inverted for this mdnsd revision: message_parse()
# returns 0 on success, but the harness does `if(!parseResult) return 0;`, so mdnsd_in() only ever sees
# messages whose parse FAILED (half-populated records no real caller can produce; every real caller
# runs mdnsd_in() only after a successful parse). Fix that one line for the duration of the build, then
# restore the upstream file so the tree stays clean (§6.2 item 16).
MDNS_HARNESS="$SRC/tests/fuzz/fuzz_mdns_message.cc"
cp "$MDNS_HARNESS" "$MDNS_HARNESS.orig"
trap 'mv -f "$MDNS_HARNESS.orig" "$MDNS_HARNESS"' EXIT
grep -q 'if(!parseResult)' "$MDNS_HARNESS" || { echo "fuzz_mdns_message.cc: expected 'if(!parseResult)' not found; re-check the harness" >&2; exit 1; }
sed -i 's/if(!parseResult)/if(parseResult)/' "$MDNS_HARNESS"

# 1) libFuzzer binaries. fuzzer-no-link puts SanCov on the whole library, not just the harness TU.
configure_and_build build-fuzz "-fsanitize=fuzzer-no-link" "-fsanitize=fuzzer;$SRC/build-fuzz/lsan_off.o"

# 2) Standalone run-once reproducers (STANDALONE_FUZZ_MAIN is C: compiled as C so the C++ harness's
#    extern "C" LLVMFuzzerTestOneInput reference keeps its C linkage). No libFuzzer runtime.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-standalone/standalone_main.o
configure_and_build build-standalone "" "$SRC/build-standalone/standalone_main.o;$SRC/build-standalone/lsan_off.o"

mv -f "$MDNS_HARNESS.orig" "$MDNS_HARNESS"; trap - EXIT

for f in $FUZZERS; do
  mv -f "build-fuzz/out/$f" "$SRC/$f"
  mv -f "build-standalone/out/$f" "$SRC/$f-standalone"
done

# 3) The project's own unit tests (Check), with NORMAL flags in a separate build tree. A deterministic
#    subset of the pure/known-answer suites: types (builtin/JSON), base64, dtoa, itoa, utf8, parse_num,
#    cj5, ziptree, mp_printf, yxml, time, PRNG, inet_pton. test.sh only RUNS these.
TESTS="check_types_builtin check_types_builtin_json check_types_json_encode check_types_json_decode
 check_base64 check_dtoa check_itoa check_utf8 check_parse_num check_cj5 check_ziptree check_mp_printf
 check_yxml check_libc_time check_pcg_basic check_musl_inet_pton"
env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake -S "$SRC" -B "$SRC/build-tests" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DUA_ENABLE_AMALGAMATION=OFF -DBUILD_SHARED_LIBS=OFF -DUA_BUILD_EXAMPLES=OFF \
  -DUA_ENABLE_ENCRYPTION=OPENSSL -DUA_BUILD_UNIT_TESTS=ON
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS" --target $TESTS
