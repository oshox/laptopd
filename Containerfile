# laptopd: Zig multicall binary + systemd units for the laptop, published as a
# FROM scratch image that laptop-setup imports with
#   COPY --from=ghcr.io/oshox/laptopd:latest /usr/ /usr/
# Tests run in the build stage, so a failing test fails the build (nothing is pushed).
FROM docker.io/library/debian:bookworm-slim AS build
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      curl ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*
ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN curl -fsSL -o /tmp/zig.tar.xz \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && tar -C /opt -xf /tmp/zig.tar.xz \
    && mv "/opt/zig-x86_64-linux-${ZIG_VERSION}" /opt/zig \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src/ src/
# Debug build first: forces full analysis of main()'s call graph, which `zig build test` skips.
RUN zig build --cache-dir /tmp/zc --global-cache-dir /tmp/zgc \
    && zig build test --cache-dir /tmp/zc --global-cache-dir /tmp/zgc
# Baseline x86_64 so the CI runner's CPU features don't leak into the binary.
RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux --cache-dir /tmp/zc --global-cache-dir /tmp/zgc
COPY dist/ /out/
RUN install -D -m0755 zig-out/bin/laptopd /out/usr/bin/laptopd \
    && for a in wallpaper-fetch wallpaper-next wallpaper-restore; do ln -s laptopd /out/usr/bin/$a; done

FROM scratch
COPY --from=build /out/ /
