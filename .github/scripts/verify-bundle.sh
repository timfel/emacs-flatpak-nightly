#!/usr/bin/env bash
set -euo pipefail

archive=${1:?usage: verify-bundle.sh ARCHIVE}
archive=$(readlink -f "$archive")
if [[ -f $archive.sha256 ]]; then
    (cd "$(dirname "$archive")" && sha256sum --check "$(basename "$archive").sha256")
fi

work=$(mktemp -d)
daemon_started=false
cleanup() {
    if $daemon_started; then
        "$prefix/bin/emacsclient" --socket-name portable-verification \
            --eval '(kill-emacs)' >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/first" "$work/relocated" "$work/home" "$work/host-bin"
tar --zstd -xf "$archive" -C "$work/first"
prefix=$(find "$work/first" -mindepth 1 -maxdepth 1 -type d -name 'Emacs-*' -print -quit)
[[ -n $prefix ]] || { echo 'Archive has no Emacs prefix' >&2; exit 1; }
mv "$prefix" "$work/relocated/"
prefix=$(find "$work/relocated" -mindepth 1 -maxdepth 1 -type d -name 'Emacs-*' -print -quit)

cat >"$work/host-bin/gcc" <<'EOF'
#!/bin/sh
printf 'host-gcc\n'
EOF
chmod +x "$work/host-bin/gcc"
export HOME="$work/home"
export PATH="$work/host-bin:/usr/local/bin:/usr/bin:/bin"
# shellcheck source=/dev/null
source "$prefix/environment.sh"

private_lib="$prefix/lib/private"
for forbidden in libgtk-3.so.0 libglib-2.0.so.0 libgio-2.0.so.0 \
                 libgobject-2.0.so.0 libpango-1.0.so.0 libcairo.so.2 \
                 libgdk_pixbuf-2.0.so.0 libwebkit2gtk-4.1.so.0 \
                 libsoup-3.0.so.0 libpng16.so.16 libjpeg.so.62 \
                 libstdc++.so.6 libgcc_s.so.1; do
    if find "$private_lib" \( -type f -o -type l \) -name "$forbidden" \
            -print -quit | grep -q .; then
        printf 'Forbidden host library is present: %s\n' "$forbidden" >&2
        exit 1
    fi
done

while IFS= read -r -d '' elf; do
    if ! type=$(readelf -h "$elf" 2>/dev/null | awk '/Type:/ { print $2; exit }'); then
        continue
    fi
    [[ $type == DYN || $type == EXEC ]] || continue
    dynamic=$(readelf -d "$elf")
    if grep -q '(RPATH)' <<<"$dynamic"; then
        printf 'Legacy RPATH found in %s\n' "$elf" >&2
        exit 1
    fi
    runpath=$(awk -F'[][]' '/RUNPATH/ { print $2; exit }' <<<"$dynamic")
    if [[ -n $runpath && $runpath != *'$ORIGIN'* ]]; then
        printf 'Non-relative RUNPATH in %s: %s\n' "$elf" "$runpath" >&2
        exit 1
    fi
done < <(find "$prefix" -type f -print0)

for forbidden in LD_LIBRARY_PATH GCC_EXEC_PREFIX COMPILER_PATH LIBRARY_PATH; do
    if grep -R -n --include='environment.sh' --include='site-start.el' \
            "$forbidden" "$prefix"; then
        printf 'Forbidden environment mechanism appears in the prefix: %s\n' "$forbidden" >&2
        exit 1
    fi
done

fingerprint=$("$prefix/bin/emacs" --fingerprint)
printf 'Portable dump fingerprint: %s\n' "$fingerprint"

cat >"$work/smoke.el" <<'EOF'
;;; -*- lexical-binding: t; -*-
(defun portable-native-smoke (value) (+ value 1))
EOF
cat >"$work/verify.el" <<EOF
;;; -*- lexical-binding: t; -*-
(let ((required '("--with-pgtk" "--with-native-compilation" "--with-tree-sitter"
                  "--with-imagemagick" "--with-xwidgets" "--with-dbus"
                  "--with-modules" "--with-rsvg" "--with-xpm")))
  (dolist (option required)
    (unless (string-match-p (regexp-quote option) system-configuration-options)
      (error "Missing configure feature: %s" option))))
(unless (native-comp-available-p) (error "Native compilation is unavailable"))
(unless (image-type-available-p 'imagemagick) (error "ImageMagick is unavailable"))
(unless (treesit-available-p) (error "Tree-sitter is unavailable"))
(require 'xwidget)
(unless (fboundp 'xwidget-webkit-new-session) (error "XWidgets are unavailable"))
(dolist (name '("GCC_EXEC_PREFIX" "COMPILER_PATH" "LIBRARY_PATH"
                "LD_LIBRARY_PATH"))
  (when (getenv name) (error "%s is present in process-environment" name)))
(when (string-match-p "libexec/native-comp" (or (getenv "PATH") ""))
  (error "Private compiler PATH leaked into process-environment"))
(with-temp-buffer
  (unless (zerop (call-process "gcc" nil t nil))
    (error "Host gcc subprocess failed"))
  (unless (equal (buffer-string) "host-gcc\n")
    (error "Emacs did not invoke the host gcc: %S" (buffer-string))))
(require 'comp)
(unless (member "-nostdlib" native-comp-driver-options)
  (error "Private native compiler driver options were not installed"))
(unless (seq-some (lambda (option)
                    (string-match-p "libexec/native-comp" option))
                  native-comp-driver-options)
  (error "Native compiler options do not identify the private toolchain"))
(let ((output (native-compile "$work/smoke.el")))
  (load output nil t)
  (unless (= (portable-native-smoke 41) 42)
    (error "Native-compiled code returned the wrong value")))
(princ "Batch, subprocess, and native-compilation checks passed\n")
EOF
"$prefix/bin/emacs" --batch -l "$work/verify.el"

"$prefix/bin/emacs" --daemon=portable-verification
daemon_started=true
result=
for _ in $(seq 1 30); do
    if result=$("$prefix/bin/emacsclient" --socket-name portable-verification \
            --eval '(+ 20 22)' 2>/dev/null); then
        [[ $result == 42 ]] || { printf 'Unexpected emacsclient result: %s\n' "$result" >&2; exit 1; }
        break
    fi
    sleep 1
done
[[ $result == 42 ]] || { echo 'emacsclient could not contact the daemon' >&2; exit 1; }
"$prefix/bin/emacsclient" --socket-name portable-verification \
    --eval '(kill-emacs)' >/dev/null
daemon_started=false

if command -v xvfb-run >/dev/null 2>&1; then
    base64 -d >"$work/pixel.png" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=
EOF
    cat >"$work/gui.el" <<EOF
;;; -*- lexical-binding: t; -*-
(let* ((image (create-image "$work/pixel.png" 'imagemagick nil))
       (size (image-size image t)))
  (unless (and (> (car size) 0) (> (cdr size) 0))
    (error "ImageMagick did not decode the test image")))
(require 'xwidget)
(xwidget-webkit-new-session "about:blank")
(sit-for 1)
(princ "ImageMagick and XWidget checks passed\n")
(kill-emacs 0)
EOF
    GDK_BACKEND=x11 dbus-run-session -- xvfb-run -a \
        "$prefix/bin/emacs" -l "$work/gui.el"
fi

printf 'Verified %s\n' "$archive"
