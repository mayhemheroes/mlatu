# Build Stage
FROM ghcr.io/evanrichter/cargo-fuzz:latest as builder

## Dependencies
RUN apt update && apt install -y clang

## Add source code to the build stage.
ADD . /src
WORKDIR /src

## The fuzzing harness requires current nightly, so one patch is needed
RUN git apply mayhem/stabilized_feature.patch

RUN echo building instrumented harnesses && \
    bash -c "pushd fuzz && cargo +nightly -Z sparse-registry fuzz build && popd" && \
    mv fuzz/target/x86_64-unknown-linux-gnu/release/parse /parse && \
    echo done

RUN echo building non-instrumented harnesses && \
    export RUSTFLAGS="--cfg fuzzing -Clink-dead-code -Cdebug-assertions -C codegen-units=1" && \
    bash -c "pushd fuzz && cargo +nightly -Z sparse-registry build --release && popd" && \
    mv fuzz/target/release/parse /parse_no_inst && \
    echo done

# Package Stage
FROM rustlang/rust:nightly

COPY --from=builder /parse /parse_no_inst /
