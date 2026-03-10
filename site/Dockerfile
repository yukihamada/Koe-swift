FROM rust:1.82-slim AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock* ./
COPY src/ src/
COPY index.html .
COPY og.svg .
COPY install.sh .
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=builder /app/target/release/koe-site /usr/local/bin/koe-site
ENV PORT=8080
EXPOSE 8080
CMD ["koe-site"]
