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
    libgtk-3-0 libwebkit2gtk-4.1-0 libgmp10 zlib1g libzstd1 >/dev/null'

run_case docker.io/library/ubuntu:24.04 '
  apt-get update >/dev/null
  apt-get install -y --no-install-recommends \
    binutils coreutils dbus-x11 file findutils grep sed tar zstd xauth xvfb \
    libgtk-3-0t64 libwebkit2gtk-4.1-0 libgmp10 zlib1g libzstd1 >/dev/null'

run_case registry.fedoraproject.org/fedora:latest '
  dnf install -y --setopt=install_weak_deps=False \
    binutils coreutils dbus-daemon file findutils grep sed tar zstd \
    xorg-x11-server-Xvfb xorg-x11-xauth \
    gtk3 webkit2gtk4.1 gmp zlib libzstd >/dev/null
  dnf clean all >/dev/null'
