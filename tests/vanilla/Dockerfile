# A clean machine for tests/vanilla/run.sh with one Neovim release, e.g.
#     docker build --build-arg NVIM_VERSION=v0.10.4 -t kotlin-lite-vanilla tests/vanilla
# tests/vanilla/docker.sh builds and runs it for every release it covers.
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git ripgrep unzip findutils \
    && rm -rf /var/lib/apt/lists/*

ARG NVIM_VERSION=stable
# the release tarball is nvim-linux64 up to 0.10, nvim-linux-x86_64 from 0.11
RUN set -e; base="https://github.com/neovim/neovim/releases/download/$NVIM_VERSION"; \
    for name in nvim-linux-x86_64 nvim-linux64; do \
        if curl -fsSL "$base/$name.tar.gz" -o /tmp/nvim.tgz; then break; fi; \
    done; \
    tar -xzf /tmp/nvim.tgz -C /opt && rm /tmp/nvim.tgz \
    && ln -s /opt/nvim-linux*/bin/nvim /usr/local/bin/nvim \
    && nvim --version | head -1

# the mounted repo belongs to the host user
RUN git config --global --add safe.directory "*"

WORKDIR /src
ENTRYPOINT ["tests/vanilla/run.sh"]
