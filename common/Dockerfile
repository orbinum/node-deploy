# Multi-stage build for Orbinum Node
# Stage 1: Build the node binary
FROM rust:1.88-bookworm AS builder

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    clang \
    libclang-dev \
    cmake \
    protobuf-compiler \
    libssl-dev \
    pkg-config \
    git \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /orbinum

# Copy source code
COPY . .

# Which Hyperbridge deployment the runtime targets. Compile-time constant: a testnet
# image built without this ships mainnet's `Polkadot(3367)`, and since `is_allowed_proxy`
# compares the whole SCALE variant with `==`, every proxied request is rejected — at
# relay time, not at build or deploy time.
#
#   docker build --build-arg CARGO_FEATURES=hyperbridge-testnet ...   # testnet
#   docker build ...                                                  # mainnet
#
# Verify the result instead of trusting the flag: the node repo ships
# `scripts/verify-coprocessor.sh <testnet|mainnet>`.
ARG CARGO_FEATURES=""

# Build the node in release mode
RUN cargo build --release --package orbinum-node \
    ${CARGO_FEATURES:+--features "$CARGO_FEATURES"}

# Stage 2: Create minimal runtime image
FROM debian:bookworm-slim

# Install runtime dependencies
# curl is needed for inserting session keys via the local RPC (docker exec)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create user
RUN useradd -m -u 1000 -U -s /bin/sh orbinum && \
    mkdir -p /data && \
    chown -R orbinum:orbinum /data

# Copy binary from builder
COPY --from=builder /orbinum/target/release/orbinum-node /usr/local/bin/orbinum-node

# Set user (numeric UID:GID so the host can resolve it — see useradd -u 1000 -U above)
USER 1000:1000

# Expose ports
# 30333: P2P
# 9944: WebSocket RPC
# 9933: HTTP RPC (if enabled)
# 9615: Prometheus metrics
EXPOSE 30333 9944 9933 9615

# Set volume for chain data
VOLUME ["/data"]

# Default command
ENTRYPOINT ["/usr/local/bin/orbinum-node"]
CMD ["--help"]
