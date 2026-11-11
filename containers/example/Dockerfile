# Example image. Copy this folder to add your own: containers/<name>/Dockerfile + VERSION.
# Renovate keeps the base image (tag + digest) up to date.
FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

USER 65534:65534
CMD ["curl", "--version"]
