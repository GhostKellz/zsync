FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ✅ sources + install base deps
RUN echo "deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse" > /etc/apt/sources.list && \
  echo "deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
  echo "deb http://archive.ubuntu.com/ubuntu noble-security main restricted universe multiverse" >> /etc/apt/sources.list && \
  rm -f /etc/apt/sources.list.d/ubuntu.sources && \
  apt-get update && \
  apt-get install -y \
  curl wget unzip tar git sudo gnupg ca-certificates \
  build-essential pkg-config libssl-dev libffi-dev \
  libicu-dev lsb-release libatomic1 gpg \
  python3-pip software-properties-common \
  liblua5.4-dev lua5.4 libtool libtool-bin libreadline-dev jq \
  dnsutils netcat-openbsd libcurl4-openssl-dev libnghttp2-dev cmake && \
  apt-get clean && rm -rf /var/lib/apt/lists/*


# ✅ NVIDIA Container Toolkit (use 22.04 source — 24.04 not available)
RUN curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && \
  curl -s -L https://nvidia.github.io/libnvidia-container/ubuntu22.04/libnvidia-container.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list && \
  apt-get update && \
  apt-get install -y nvidia-container-toolkit && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# ✅ Create non-root runner user
RUN useradd -m runner && echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# ✅ Install latest Zig nightly before switching to non-root
RUN set -eux; \
  JSON=$(curl -sL https://ziglang.org/download/index.json); \
  ZIG_TARBALL_URL=$(echo "$JSON" | jq -r '.master."x86_64-linux".tarball'); \
  curl -LO "$ZIG_TARBALL_URL"; \
  TARBALL=$(basename "$ZIG_TARBALL_URL"); \
  tar -xf "$TARBALL"; \
  ZIG_DIR=$(tar -tf "$TARBALL" | head -1 | cut -f1 -d"/"); \
  mv "$ZIG_DIR" /opt/zig && rm "$TARBALL"; \
  ln -s /opt/zig/zig /usr/local/bin/zig

# ✅ Set global path for Zig
ENV PATH="/opt/zig:$PATH"

# ✅ Drop privileges
USER runner
WORKDIR /home/runner

# ✅ Setup GitHub Actions runner
WORKDIR /runner
COPY --chown=runner:runner entrypoint.sh .
RUN chmod +x entrypoint.sh && \
  curl -o actions-runner.tar.gz -L https://github.com/actions/runner/releases/download/v2.324.0/actions-runner-linux-x64-2.324.0.tar.gz && \
  tar xzf actions-runner.tar.gz && rm actions-runner.tar.gz

ENTRYPOINT ["/runner/entrypoint.sh"]

