FROM rust:1.86-slim AS builder
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
COPY support.html .
# Added by PR #2 (audit); main.rs include_str!()s these so they must be in the build context.
COPY robots.txt .
COPY sitemap.xml .
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates libssl3 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/koe-site /usr/local/bin/koe-site
ENV PORT=8080
EXPOSE 8080
CMD ["koe-site"]
