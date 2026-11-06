# syntax=docker/dockerfile:1.4
FROM debian:bookworm-slim

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y \
    wget gnupg lsb-release ca-certificates && \
    echo "deb http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-17 main" > /etc/apt/sources.list.d/llvm.list && \
    wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc >/dev/null && \
    apt-get update && apt-get install -y \
    build-essential \
    clang-17 \
    lld-17 \
    llvm-17 \
    bc \
    flex \
    bison \
    libelf-dev \
    libssl-dev \
    xz-utils \
    cpio \
    python3 && \
    update-alternatives --install /usr/bin/clang clang /usr/bin/clang-17 100 \
        --slave /usr/bin/clang++ clang++ /usr/bin/clang++-17 \
        --slave /usr/bin/ld.lld ld.lld /usr/bin/ld.lld-17 \
        --slave /usr/bin/llvm-ar llvm-ar /usr/bin/llvm-ar-17 \
        --slave /usr/bin/llvm-nm llvm-nm /usr/bin/llvm-nm-17 \
        --slave /usr/bin/llvm-strip llvm-strip /usr/bin/llvm-strip-17 \
        --slave /usr/bin/llvm-objcopy llvm-objcopy /usr/bin/llvm-objcopy-17 \
        --slave /usr/bin/llvm-objdump llvm-objdump /usr/bin/llvm-objdump-17 \
        --slave /usr/bin/llvm-readelf llvm-readelf /usr/bin/llvm-readelf-17 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
