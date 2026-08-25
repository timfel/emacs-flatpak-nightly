#!/usr/bin/env bash
set -euo pipefail

archive=${1:?usage: verify-containers.sh ARCHIVE}
archive=$(readlink -f "$archive")
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
engine=${CONTAINER_ENGINE:-podman}

proxy_args=()
for name in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
    [[ -n ${!name:-} ]] && proxy_args+=(--env "$name")
done

run_case() {
    local image=$1 install=$2
    printf '\nVerifying with %s\n' "$image"
    "$engine" run --rm "${proxy_args[@]}" \
        -v "$ROOT:/source:ro" -v "$archive:/artifact/Emacs.tar.zst:ro" \
        "$image" bash -lc "$install; /source/.github/scripts/verify-bundle.sh /artifact/Emacs.tar.zst"
}

run_case docker.io/library/debian:bookworm '
  apt-get update >/dev/null
  apt-get install -y --no-install-recommends \
    binutils coreutils dbus-x11 file findutils grep sed tar zstd xauth xvfb \
    libacl1 libasound2 libattr1 libbz2-1.0 libcairo2 libdbus-1-3 \
    libfontconfig1 libfreetype6 libgdk-pixbuf-2.0-0 libgif7 libgmp10 libgnutls30 libgpm2 \
    libgtk-3-0 libharfbuzz0b libjpeg62-turbo liblcms2-2 libotf1 libpng16-16 \
    librsvg2-2 libselinux1 libsqlite3-0 libsystemd0 libtiff6 libtinfo6 \
    libtree-sitter0 libwebkit2gtk-4.1-0 libwebp7 libwebpdemux2 libxml2 \
    zlib1g libzstd1 >/dev/null'

run_case docker.io/library/ubuntu:24.04 '
  apt-get update >/dev/null
  apt-get install -y --no-install-recommends \
    binutils coreutils dbus-x11 file findutils grep sed tar zstd xauth xvfb \
    libacl1 libasound2t64 libattr1 libbz2-1.0 libcairo2 libdbus-1-3 \
    libfontconfig1 libfreetype6 libgdk-pixbuf-2.0-0 libgif7 libgmp10 libgnutls30t64 libgpm2 \
    libgtk-3-0t64 libharfbuzz0b libjpeg-turbo8 liblcms2-2 libotf1 libpng16-16t64 \
    librsvg2-2 libselinux1 libsqlite3-0 libsystemd0 libtiff6 libtinfo6 \
    libtree-sitter0 libwebkit2gtk-4.1-0 libwebp7 libwebpdemux2 libxml2 \
    zlib1g libzstd1 >/dev/null'

run_case registry.fedoraproject.org/fedora:latest '
  dnf install -y --setopt=install_weak_deps=False \
    binutils coreutils dbus-daemon file findutils grep sed tar zstd \
    xorg-x11-server-Xvfb xorg-x11-xauth \
    acl alsa-lib attr bzip2-libs cairo dbus-libs fontconfig freetype \
    gdk-pixbuf2 giflib gmp gnutls gpm-libs gtk3 harfbuzz libjpeg-turbo lcms2 libotf libpng \
    librsvg2 libselinux libtiff libwebp libxml2 ncurses-libs sqlite-libs \
    systemd-libs tree-sitter webkit2gtk4.1 zlib libzstd >/dev/null
  dnf clean all >/dev/null'
