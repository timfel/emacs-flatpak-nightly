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
export PATH="$prefix/bin:$work/host-bin:/usr/local/bin:/usr/bin:/bin"
[[ ! -e $prefix/environment.sh ]] || {
    echo 'The prefix unexpectedly contains environment.sh' >&2
    exit 1
}

private_lib="$prefix/lib/private"
toolchain="$prefix/libexec/native-comp"
tool_lib="$toolchain/lib"
is_host_glibc() {
    local name=${1##*/}
    case "$name" in
        ld-linux*.so.*|ld64.so.*|libc.so.*|libm.so.*|libmvec.so.*|\
        libdl.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|libutil.so.*|\
        libanl.so.*|libBrokenLocale.so.*|libnss_*.so.*|libthread_db.so.*)
            return 0 ;;
        *) return 1 ;;
    esac
}

for library in "$private_lib"/* "$tool_lib"/*; do
    [[ -e $library || -L $library ]] || continue
    if is_host_glibc "${library##*/}"; then
        printf 'Host glibc library is present: %s\n' "${library##*/}" >&2
        exit 1
    fi
done
for forbidden in libdbus-1.so.* libgio-2.0.so.* libgtk-*.so.* \
                 librsvg-*.so.* libwebkit2gtk-*.so.*; do
    if compgen -G "$private_lib/$forbidden" >/dev/null; then
        printf 'Removed platform library is present: %s\n' "$forbidden" >&2
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
    dependency_dir=$private_lib
    [[ $elf == "$toolchain/"* ]] && dependency_dir=$tool_lib
    while IFS= read -r needed; do
        is_host_glibc "$needed" && continue
        if [[ ! -e $dependency_dir/$needed ]]; then
            printf 'Bundled dependency %s required by %s is missing\n' \
                "$needed" "$elf" >&2
            exit 1
        fi
    done < <(awk -F'[][]' '/NEEDED/ { print $2 }' <<<"$dynamic")
done < <(find "$prefix" -type f -print0)

for forbidden in LD_LIBRARY_PATH GCC_EXEC_PREFIX COMPILER_PATH LIBRARY_PATH; do
    if grep -R -n --include='emacs' --include='emacsclient' \
            --include='site-start.el' "$forbidden" "$prefix"; then
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
(let ((required '("--with-x-toolkit=lucid" "--with-native-compilation"
                  "--with-tree-sitter" "--with-imagemagick"
                  "--with-modules" "--with-xpm"))
      (forbidden '("--with-pgtk" "--with-dbus" "--with-xwidgets"
                   "--with-rsvg" "--with-libsystemd" "--with-selinux")))
  (dolist (option required)
    (unless (string-match-p (regexp-quote option) system-configuration-options)
      (error "Missing configure feature: %s" option)))
  (dolist (option forbidden)
    (when (string-match-p (regexp-quote option) system-configuration-options)
      (error "Removed configure feature is enabled: %s" option))))
(unless (native-comp-available-p) (error "Native compilation is unavailable"))
(unless (image-type-available-p 'imagemagick) (error "ImageMagick is unavailable"))
(unless (treesit-available-p) (error "Tree-sitter is unavailable"))
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

command -v xvfb-run >/dev/null 2>&1 || {
    echo 'xvfb-run is required for Lucid GUI verification' >&2
    exit 1
}
base64 -d >"$work/pixel.png" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=
EOF
cat >"$work/gui.el" <<EOF
;;; -*- lexical-binding: t; -*-
(let* ((image (create-image "$work/pixel.png" 'imagemagick nil))
       (size (image-size image t)))
  (unless (and (> (car size) 0) (> (cdr size) 0))
    (error "ImageMagick did not decode the test image")))
(unless (eq window-system 'x)
  (error "Lucid build did not create an X frame: %S" window-system))
(unless (member "LUCID" (split-string system-configuration-features))
  (error "The running GUI does not report the Lucid toolkit"))
(princ "ImageMagick and Lucid X11 checks passed\n")
(kill-emacs 0)
EOF
xvfb-run -a "$prefix/bin/emacs" -l "$work/gui.el"

printf 'Verified %s\n' "$archive"
