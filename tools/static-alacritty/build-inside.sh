#!/usr/bin/env bash
# Run by build-static-alacritty.sh inside the CentOS 7 builder image.

set -Eeuo pipefail
IFS=$'\n\t'

readonly source_root=/source
readonly work_root=/work
readonly checkout_root="$work_root/src/alacritty-v${ALACRITTY_VERSION}"
readonly stage_root="$work_root/stage"
readonly artifact_root="$work_root/artifacts"
readonly expected_remote=https://github.com/alacritty/alacritty.git

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ -n "${ALACRITTY_VERSION:-}" ]] || die 'ALACRITTY_VERSION is not set'
[[ "${ALACRITTY_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || die 'ALACRITTY_COMMIT is invalid'
[[ -f "$source_root/tools/static-alacritty/onefile.go.in" ]] ||
    die 'launcher template is missing'
[[ -d "$work_root" && -w "$work_root" ]] || die '/work is not writable'
[[ "$(uname -m)" == x86_64 ]] || die 'only x86_64 is supported'

mkdir -p -- "$work_root/src" "$artifact_root"
if [[ ! -d "$checkout_root/.git" ]]; then
    [[ ! -e "$checkout_root" ]] || die "$checkout_root exists but is not a Git checkout"
    git clone --depth 1 --branch "v${ALACRITTY_VERSION}" \
        "$expected_remote" "$checkout_root"
fi

git_at_checkout() {
    git --git-dir="$checkout_root/.git" --work-tree="$checkout_root" "$@"
}

actual_remote="$(git_at_checkout config --get remote.origin.url)"
[[ "$actual_remote" == "$expected_remote" ]] ||
    die "cached checkout has unexpected origin: $actual_remote"
actual_commit="$(git_at_checkout rev-parse HEAD)"
[[ "$actual_commit" == "$ALACRITTY_COMMIT" ]] ||
    die "v${ALACRITTY_VERSION} resolved to $actual_commit, expected $ALACRITTY_COMMIT"
[[ -z "$(git_at_checkout status --short)" ]] ||
    die "cached upstream checkout is dirty: $checkout_root"

# Keep the verified upstream checkout and Cargo registry cache untouched.
# Patch only a checksum-verified dependency in a disposable build tree.
compat_root="$work_root/centos7-compat"
rm -rf -- "$compat_root"
mkdir -p -- "$compat_root"
cp -a -- "$checkout_root" "$compat_root/source"
crate_name=rustix-openpty-0.2.0
crate_sha256=1de16c7c59892b870a6336f185dc10943517f1327447096bbb7bb32cd85e2393
crate_archive="$compat_root/$crate_name.crate"
cached_crate="$(find "$CARGO_HOME/registry/cache" -name "$crate_name.crate" -print -quit 2>/dev/null || true)"
if [[ -n "$cached_crate" ]]; then
    cp -- "$cached_crate" "$crate_archive"
else
    curl --fail --location --retry 5 --output "$crate_archive" \
        "https://static.crates.io/crates/rustix-openpty/$crate_name.crate"
fi
printf '%s  %s\n' "$crate_sha256" "$crate_archive" | sha256sum --check --status ||
    die 'rustix-openpty archive checksum mismatch'
mkdir -p -- "$compat_root/rustix-openpty"
tar -xzf "$crate_archive" --strip-components=1 -C "$compat_root/rustix-openpty"
cd -- "$compat_root"
git apply --check --directory=rustix-openpty \
    "$source_root/tools/static-alacritty/rustix-openpty-centos7.patch"
git apply --directory=rustix-openpty \
    "$source_root/tools/static-alacritty/rustix-openpty-centos7.patch"
cd -- "$compat_root/source"
cat >> Cargo.toml <<'PATCH_CONFIG'

[patch.crates-io]
rustix-openpty = { path = "../rustix-openpty" }
PATCH_CONFIG
# Change only this package's source to a local path; preserve all other pins.
awk '
    /^\[\[package\]\]/ { local_crate = 0 }
    /^name = "rustix-openpty"$/ { local_crate = 1 }
    local_crate && /^(source|checksum) = / { next }
    { print }
' Cargo.lock > Cargo.lock.local
mv Cargo.lock.local Cargo.lock
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS='-C link-arg=-Wl,--disable-new-dtags,-rpath,$ORIGIN/../lib'

cargo build \
    --locked \
    --release \
    --target x86_64-unknown-linux-gnu \
    --package alacritty \
    --no-default-features \
    --features x11

built_binary="$CARGO_TARGET_DIR/x86_64-unknown-linux-gnu/release/alacritty"
[[ -x "$built_binary" ]] || die "Alacritty binary is missing: $built_binary"
version_output="$($built_binary --version)"
expected_version_output="alacritty $ALACRITTY_VERSION (${ALACRITTY_COMMIT:0:7})"
[[ "$version_output" == "$expected_version_output" ]] ||
    die "unexpected Alacritty version: $version_output"

rm -rf -- "$stage_root"
mkdir -p -- \
    "$stage_root/bin" \
    "$stage_root/etc/fonts" \
    "$stage_root/lib" \
    "$stage_root/share/fonts" \
    "$stage_root/share/terminfo"
install -m 0755 -- "$built_binary" "$stage_root/bin/alacritty"
strip --strip-unneeded "$stage_root/bin/alacritty"

is_elf() {
    [[ -f "$1" && "$(od -An -tx1 -N4 -- "$1" 2>/dev/null | tr -d ' \n')" == 7f454c46 ]]
}

is_host_runtime() {
    case "$1" in
    ld-linux*.so* | libanl.so* | libBrokenLocale.so* | libc.so* | libdl.so* | libm.so* | libnss_*.so* | libpthread.so* | libresolv.so* | librt.so* | libutil.so*)
        return 0
        ;;
    # Alacritty obtains these from the host at runtime.  Bundling Mesa's
    # dispatch layer would hide vendor drivers and commonly breaks NVIDIA.
    libdrm*.so* | libEGL.so* | libgbm.so* | libGL.so* | libGLdispatch.so* | libGLES*.so* | libglapi.so* | libGLX*.so* | libOpenGL.so* | libvulkan.so*)
        return 0
        ;;
    esac
    return 1
}

copy_runtime_library() {
    local source_path="$1" basename_ destination
    [[ "$source_path" == /* && -e "$source_path" ]] || return 0
    basename_="$(basename -- "$source_path")"
    is_host_runtime "$basename_" && return 0
    destination="$stage_root/lib/$basename_"
    if [[ -e "$destination" ]]; then
        cmp -s -- "$source_path" "$destination" ||
            die "runtime library basename collision: $source_path and $destination"
        return 0
    fi
    cp -L --preserve=mode,timestamps -- "$source_path" "$destination"
}

find_library() {
    local soname="$1"
    ldconfig -p | awk -v wanted="$soname" '$1 == wanted && !found { print $NF; found = 1 }'
}

# Libraries loaded through dlopen(3) do not appear in DT_NEEDED.  Keep this
# list synchronized with winit 0.30.13, glutin 0.32.3 and xkbcommon-dl 0.4.2.
for soname in \
    libX11.so.6 \
    libX11-xcb.so.1 \
    libXcursor.so.1 \
    libXi.so.6 \
    libXrender.so.1 \
    libxcb.so.1 \
    libxkbcommon.so.0 \
    libxkbcommon-x11.so.0; do
    library_path="$(find_library "$soname")"
    [[ -n "$library_path" ]] || die "required runtime library is unavailable: $soname"
    copy_runtime_library "$library_path"
done

# Copy the transitive dependency closure, excluding glibc and the graphics
# driver boundary identified by is_host_runtime().
for pass in 1 2 3 4 5 6 7 8; do
    before="$(find "$stage_root/lib" -type f | wc -l)"
    missing_file="$work_root/missing-libraries.txt"
    : > "$missing_file"
    while IFS= read -r -d '' elf; do
        is_elf "$elf" || continue
        ldd_output="$(LD_LIBRARY_PATH="$stage_root/lib" ldd "$elf" 2>&1 || true)"
        while IFS= read -r missing; do
            [[ -n "$missing" ]] && printf '%s: %s\n' "$elf" "$missing" >> "$missing_file"
        done < <(awk '/=> not found/ { print $1 }' <<< "$ldd_output")
        while IFS= read -r library_path; do
            [[ -n "$library_path" ]] && copy_runtime_library "$library_path"
        done < <(awk '/=> \// { print $3; next } /^[[:space:]]*\// { print $1 }' <<< "$ldd_output")
    done < <(find "$stage_root/bin" "$stage_root/lib" -type f -print0)
    [[ ! -s "$missing_file" ]] || {
        cat "$missing_file" >&2
        die 'one or more linked libraries could not be resolved'
    }
    after="$(find "$stage_root/lib" -type f | wc -l)"
    [[ "$after" != "$before" ]] || break
    [[ "$pass" != 8 ]] || die 'runtime dependency closure did not converge'
done

# Supply a fallback monospace font and the matching CentOS 7 Fontconfig rules.
# CentOS uses absolute symlinks from /etc/fonts/conf.d into /usr/share; resolve
# them now so the payload contains no link escaping its extraction root.
cp -aL /etc/fonts/. "$stage_root/etc/fonts/"
while IFS= read -r -d '' font; do
    cp --preserve=mode,timestamps -- "$font" "$stage_root/share/fonts/"
done < <(find /usr/share/fonts/dejavu -type f -name 'DejaVuSansMono*.ttf' -print0)
[[ -n "$(find "$stage_root/share/fonts" -type f -name '*.ttf' -print -quit)" ]] ||
    die 'the fallback DejaVu Sans Mono fonts are missing'
sed -i '/<fontconfig>/a\  <dir>@ALACRITTY_FONT_DIR@</dir>' \
    "$stage_root/etc/fonts/fonts.conf"

# Bundle the terminfo entries selected by Alacritty 0.17.0.
tic -x -o "$stage_root/share/terminfo" extra/alacritty.info

cat > "$stage_root/PORTABILITY.txt" <<EOF
Alacritty ${ALACRITTY_VERSION}, commit ${ALACRITTY_COMMIT}

Compatibility patch: rustix-openpty 0.2.0 falls back on ENOTTY for old kernels.

This payload was compiled on CentOS 7 and is embedded in a static one-file
launcher.  It includes ordinary linked libraries, dlopen-loaded X11 and
xkbcommon libraries, Fontconfig configuration, DejaVu Sans Mono, and terminfo.

Required host interfaces: Linux x86_64, glibc 2.17 or newer, an X server, and
a working OpenGL/GLX or EGL implementation supplied by the graphics driver.
Those interfaces are intentionally not bundled or claimed to be statically
linked.  Wayland support is disabled for compatibility with CentOS 7.
EOF

# The main executable uses old-style DT_RPATH because it is inherited while
# resolving the transitive dependencies of libraries opened with dlopen().
readelf -dW "$stage_root/bin/alacritty" | grep -Fq '(RPATH)'
readelf -dW "$stage_root/bin/alacritty" | grep -Fq '$ORIGIN/../lib'
LD_LIBRARY_PATH="$stage_root/lib" "$stage_root/bin/alacritty" --version |
    grep -Fx "$expected_version_output"

launcher_dir="$work_root/launcher"
rm -rf -- "$launcher_dir"
mkdir -p -- "$launcher_dir"
cp -- "$source_root/tools/static-alacritty/onefile.go.in" "$launcher_dir/main.go"

source_date_epoch="$(git_at_checkout show -s --format=%ct HEAD)"
find "$stage_root" -exec touch -h -d "@${source_date_epoch}" {} +
tar --owner=0 --group=0 --numeric-owner -C "$stage_root" -cf \
    "$launcher_dir/payload.tar" .
gzip -9 -n "$launcher_dir/payload.tar"

payload_file="$launcher_dir/payload.tar.gz"
payload_sha256="$(sha256sum "$payload_file" | awk '{print $1}')"
build_id="alacritty-${ALACRITTY_VERSION}-${ALACRITTY_COMMIT:0:12}"

CGO_ENABLED=0 go build \
    -buildvcs=false \
    -trimpath \
    -ldflags "-s -w -buildid= -X main.buildID=$build_id -X main.payloadSHA256=$payload_sha256" \
    -o "$artifact_root/alacritty-onefile" \
    "$launcher_dir/main.go"

is_elf "$artifact_root/alacritty-onefile" || die 'the outer launcher is not an ELF file'
if readelf -lW "$artifact_root/alacritty-onefile" | grep -q ' INTERP '; then
    die 'the outer launcher has a dynamic interpreter'
fi
if readelf -dW "$artifact_root/alacritty-onefile" 2>/dev/null | grep -q '(NEEDED)'; then
    die 'the outer launcher has dynamic dependencies'
fi
"$artifact_root/alacritty-onefile" --version |
    grep -Fx "$expected_version_output"
