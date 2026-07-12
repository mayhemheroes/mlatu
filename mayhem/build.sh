#!/usr/bin/env bash
#
# mlatu/mayhem/build.sh — build the `parse` cargo-fuzz target as a sanitized libFuzzer
# binary (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus the KAT oracle
# test binary that mayhem/test.sh runs.
#
# Target (mayhem/fuzz/fuzz_targets/parse.rs — ported from the old fork's fuzz/ crate):
#   parse — UTF-8 input driven through mlatu_lib::parse::rules() and ::terms(), the
#           mlatu language parser (mlatu-lang/libraries, the library this CLI wraps;
#           pinned by rev in mayhem/fuzz/Cargo.toml, same rev the old fork locked).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE. This
# first (online) build populates the cargo registry + git-checkout caches under
# $CARGO_HOME; the re-run (CARGO_NET_OFFLINE=true, exported by the rlenv runtime)
# resolves everything from that cache — so no `--offline` here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# ── DWARF < 4 enforcement (§6.2 item 10) ────────────────────────────────────────────
# Rust's ASan runtime is compiled with the nightly's bundled LLVM (DWARF 5) and is linked
# BEFORE project code; strip its debug sections so it contributes no .debug_info. The
# stripped .a is baked into the image, so the offline PATCH re-run sees the same file.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
  echo "Stripping debug info from Rust ASan runtime (DWARF < 4): $ASAN_RT"
  objcopy --strip-debug "$ASAN_RT"
fi
# libfuzzer-sys compiles libFuzzer from C++ via the cc crate — force DWARF 3 there too.
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# DWARF ≤ 3 debug info for our Rust CUs; env-overridable (rlenv may export RUST_DEBUG_FLAGS).
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=2}"

# Sanitizer: Rust instrumentation goes through RUSTFLAGS (-Zsanitizer=address), the
# cargo-fuzz/OSS-Fuzz Rust path — clang's $SANITIZER_FLAGS does not apply to rustc
# (no C/C++ compiled here beyond libfuzzer-sys's bundled runtime, handled above).

# The fuzz crate is ADDITIVE under mayhem/fuzz/ (ported from the old fork's root fuzz/
# crate; upstream ships no fuzz crate). The unused `mlatu` path-dep was dropped — the
# harness only exercises mlatu_lib, and upstream's crate needs a removed nightly feature
# (#![feature(stdio_locked)]) that would demand editing upstream source.
FUZZ_DIR="mayhem/fuzz"
FUZZ_TARGETS=(parse)
TRIPLE="x86_64-unknown-linux-gnu"

# OSS-Fuzz Rust libFuzzer+ASan flags. --cfg fuzzing matches libfuzzer-sys; note RUSTFLAGS
# (env) supersedes upstream .cargo/config.toml's target rustflags (-Zshare-generics), by
# cargo's precedence rules — the config's linker=clang line still applies and is fine.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (image-default nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
done

TARGET_DIR="$(cargo metadata --no-deps --format-version 1 --manifest-path "$FUZZ_DIR/Cargo.toml" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')"
REL="$TARGET_DIR/$TRIPLE/release"
for t in "${FUZZ_TARGETS[@]}"; do
  bin="$REL/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; ls -la "$REL" >&2 || true; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── Build the KAT oracle test binary (normal flags, NO sanitizer) ───────────────────
# Upstream ships NO test suite (no #[test], no tests/ — the crate is a thin CLI/editor
# over mlatu_lib), so mayhem/oracle/ is an AUTHORED known-answer suite over the same
# library code path the fuzz target drives. test.sh only RUNS the binary built here.
echo "=== building oracle test binary (cargo test --no-run, normal flags) ==="
ORACLE_BIN="$(RUSTFLAGS="" cargo test --no-run --manifest-path mayhem/oracle/Cargo.toml \
    --message-format=json 2>/dev/null \
  | python3 -c '
import json, sys
exe = None
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    if m.get("reason") == "compiler-artifact" and m.get("profile", {}).get("test") and m.get("executable"):
        exe = m["executable"]
print(exe or "")')"
[ -n "$ORACLE_BIN" ] && [ -x "$ORACLE_BIN" ] || { echo "ERROR: oracle test binary not produced" >&2; exit 1; }
cp "$ORACLE_BIN" /mayhem/mlatu-oracle-test
echo "built /mayhem/mlatu-oracle-test"

echo "build.sh complete:"
ls -la /mayhem/parse /mayhem/mlatu-oracle-test
