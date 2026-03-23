FROM rust:1.85-slim AS builder
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Cargo.toml Cargo.lock* ./
COPY src/ src/
COPY index.html .
COPY og.svg .
COPY og.png .
COPY install.sh .
COPY elio-icon.png .
COPY vs-notta.html .
COPY pricing.html .
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates libssl3 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/koe-site /usr/local/bin/koe-site
ENV PORT=8080
EXPOSE 8080
CMD ["koe-site"]
