# syntax=docker/dockerfile:1.4
FROM debian:bookworm-slim

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y \
    build-essential \
    clang \
    lld \
    llvm \
    wget \
    gnupg \
    lsb-release \
    software-properties-common && \
    echo "deb http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-17 main" > /etc/apt/sources.list.d/llvm.list && \
    wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc >/dev/null && \
    apt-get update && apt-get install -y \
    clang-17 \
    lld-17 \
    llvm-17 \
    clang-tools-17 && \
    update-alternatives --install /usr/bin/clang clang /usr/bin/clang-17 100 \
        --slave /usr/bin/clang++ clang++ /usr/bin/clang++-17 \
        --slave /usr/bin/ld.lld ld.lld /usr/bin/ld.lld-17 \
        --slave /usr/bin/llvm-ar llvm-ar /usr/bin/llvm-ar-17 \
        --slave /usr/bin/llvm-nm llvm-nm /usr/bin/llvm-nm-17 \
        --slave /usr/bin/llvm-strip llvm-strip /usr/bin/llvm-strip-17 \
        --slave /usr/bin/llvm-objcopy llvm-objcopy /usr/bin/llvm-objcopy-17 \
        --slave /usr/bin/llvm-objdump llvm-objdump /usr/bin/llvm-objdump-17 \
        --slave /usr/bin/llvm-readelf llvm-readelf /usr/bin/llvm-readelf-17 && \
    apt-get install -y \
    curl \
    git \
    python3 \
    xz-utils \
    squashfs-tools \
    erofs-utils \
    dosfstools \
    e2fsprogs \
    util-linux \
    fdisk \
    fakeroot \
    ca-certificates \
    pkg-config \
    pkgconf \
    rsync \
    gawk \
    bison \
    texinfo \
    meson \
    ninja-build \
    gperf \
    python3-jinja2 \
    python3-pip \
    gettext \
    autopoint \
    autoconf \
    automake \
    libtool \
    cmake \
    flex \
    libelf-dev \
    libssl-dev \
    libpam0g-dev \
    libdevmapper-dev \
    libpopt-dev \
    libargon2-dev \
    libzstd-dev \
    zlib1g-dev \
    uuid-dev \
    libblkid-dev \
    bc \
    dwarves \
    kmod \
    python3-pefile \
    python3-pyelftools \
    mtools \
    btrfs-progs \
    && rm -rf /var/lib/apt/lists/*

# Rust toolchain for uutils
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/root/.cargo/git,sharing=locked \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --profile minimal --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /build
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
