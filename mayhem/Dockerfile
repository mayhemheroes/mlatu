# syntax=docker/dockerfile:1.7
#
# mlatu commit-image Dockerfile — RUST target (cargo / cargo-fuzz), built ON TOP of the
# org C/C++ base (ghcr.io/mayhemheroes/base). The base ships no Rust toolchain, so this
# image installs a pinned nightly + cargo-fuzz at a FIXED, $HOME-independent prefix
# (/opt/toolchains/rust) with CARGO_HOME/RUSTUP_HOME pinned there as ENV (SPEC §6.2
# item 8) — the cargo registry the first (online) build populates is found again by the
# air-gapped PATCH re-run of mayhem/build.sh.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mlatu-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Declared for parity with the C/C++ template; Rust instrumentation goes through RUSTFLAGS
# (-Zsanitizer=address) in build.sh, not clang's $SANITIZER_FLAGS.
ARG SANITIZER_FLAGS

# Pin the nightly by DATE (cargo-fuzz needs nightly for -Zsanitizer=address) and cargo-fuzz by version.
ARG RUST_CHANNEL=nightly-2025-09-05
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH} \
    # Upstream's rust-toolchain.toml pins nightly-2021-10-23 (long EOL, would make rustup
    # download a second toolchain at build time — not air-gapped). Force the image's pinned
    # channel instead; RUSTUP_TOOLCHAIN overrides the file.
    RUSTUP_TOOLCHAIN=${RUST_CHANNEL}

USER root
RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): hand the whole
 # prefix to 2000 so both can read the toolchain and read/refresh the cargo registry cache.
 && chown -R 2000:2000 /opt/toolchains/rust \
 && rustc --version && cargo --version && cargo fuzz --version

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz target(s).
RUN bash mayhem/build.sh

# Run the functional oracle at build time (a failing suite fails the build).
RUN bash mayhem/test.sh

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
