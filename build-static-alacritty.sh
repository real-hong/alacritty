#!/usr/bin/env bash
# Build a CentOS 7-compatible, dependency-contained Alacritty executable.
#
# Alacritty cannot be made into a usable, literally fully-static Linux GUI
# executable: winit and glutin load X11, xkbcommon, and the OpenGL driver with
# dlopen(3).  This builder therefore creates a genuinely static outer launcher
# containing the CentOS 7-built Alacritty and its ordinary user-space libraries.
# A host X server and OpenGL/EGL driver are still required.

set -Eeuo pipefail
IFS=$'\n\t'

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly containerfile="$script_dir/tools/static-alacritty/Containerfile"
readonly inner_builder="$script_dir/tools/static-alacritty/build-inside.sh"
readonly alacritty_version=0.17.0
readonly alacritty_commit=94e7c8874e526b1e67b349d9ba30ddf81669119e
readonly rust_version=1.85.0
readonly go_version=1.25.0

container_engine="${CONTAINER_ENGINE:-}"
centos_vault_base="${CENTOS_VAULT_BASE:-https://vault.centos.org/7.9.2009}"
work_dir="$script_dir/build/static-alacritty"
output_path=""
builder_image=""
rebuild_image=0

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./build-static-alacritty.sh [options]

Build Alacritty 0.17.0 in CentOS 7 and package it in a static one-file launcher.

Options:
  --engine NAME       Container engine: podman or docker (auto-detected)
  --image NAME        Builder image name (default: version-derived)
  --work-dir PATH     Cache/work directory (default: build/static-alacritty)
  --output PATH       Final executable path (default: WORK_DIR/alacritty-*)
  --vault-url URL     CentOS 7 Vault base URL
  --rebuild-image     Rebuild the builder image without its layer cache
  -h, --help          Show this help

The output file is a static ELF launcher and needs no installed Alacritty/X11/
font packages.  At first launch it extracts a verified, content-addressed
payload under the user's cache directory.  A Linux x86_64 kernel, X server,
glibc 2.17+ and a working OpenGL/GLX or EGL driver are still required.  These
host interfaces cannot safely be statically linked into Alacritty.
EOF
}

while (($#)); do
    case "$1" in
    --engine)
        (($# >= 2)) || die '--engine needs an argument'
        container_engine="$2"
        shift 2
        ;;
    --image)
        (($# >= 2)) || die '--image needs an argument'
        builder_image="$2"
        shift 2
        ;;
    --work-dir)
        (($# >= 2)) || die '--work-dir needs an argument'
        work_dir="$2"
        shift 2
        ;;
    --output)
        (($# >= 2)) || die '--output needs an argument'
        output_path="$2"
        shift 2
        ;;
    --vault-url)
        (($# >= 2)) || die '--vault-url needs an argument'
        centos_vault_base="${2%/}"
        shift 2
        ;;
    --rebuild-image)
        rebuild_image=1
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        die "unknown option: $1"
        ;;
    esac
done

[[ "$(uname -s)" == Linux ]] || die 'this builder only supports Linux'
[[ "$(uname -m)" == x86_64 ]] || die 'only Linux x86_64 is supported'
[[ -f "$containerfile" && -x "$inner_builder" ]] ||
    die 'the tools/static-alacritty build helpers are missing or not executable'

if [[ -z "$container_engine" ]]; then
    if command -v podman >/dev/null 2>&1; then
        container_engine=podman
    elif command -v docker >/dev/null 2>&1; then
        container_engine=docker
    else
        die 'podman or docker is required'
    fi
fi
case "$container_engine" in
podman | docker) ;;
*) die "unsupported container engine: $container_engine" ;;
esac
command -v "$container_engine" >/dev/null 2>&1 ||
    die "$container_engine is not installed"
for required_command in awk du install readelf sha256sum; do
    command -v "$required_command" >/dev/null 2>&1 ||
        die "$required_command is required"
done

if [[ -z "$builder_image" ]]; then
    builder_image="localhost/alacritty-onefile-builder:centos7-rust${rust_version}-go${go_version}"
fi

mkdir -p -- "$work_dir"
work_dir="$(cd -- "$work_dir" && pwd -P)"
[[ "$work_dir" != / && "$work_dir" != "$script_dir" ]] ||
    die 'the work directory must not be / or the project root'

if [[ -z "$output_path" ]]; then
    output_path="$work_dir/alacritty-onefile-${alacritty_version}-x86_64"
elif [[ "$output_path" != /* ]]; then
    output_path="$PWD/$output_path"
fi
mkdir -p -- "$(dirname -- "$output_path")"

build_args=(
    build
    --network=host
    --build-arg "CENTOS_VAULT_BASE=$centos_vault_base"
    --build-arg "GO_VERSION=$go_version"
    --build-arg "RUST_VERSION=$rust_version"
    --tag "$builder_image"
    --file "$containerfile"
)
if [[ -n "${HTTP_PROXY:-}" ]]; then
    build_args+=(--build-arg "HTTP_PROXY=$HTTP_PROXY")
fi
if [[ -n "${HTTPS_PROXY:-}" ]]; then
    build_args+=(--build-arg "HTTPS_PROXY=$HTTPS_PROXY")
fi
if ((rebuild_image)); then
    build_args+=(--no-cache)
fi
build_args+=("$script_dir/tools/static-alacritty")

printf 'Building CentOS 7 builder image %s ...\n' "$builder_image"
"$container_engine" "${build_args[@]}"

mkdir -p -- \
    "$work_dir/artifacts" \
    "$work_dir/cargo-home" \
    "$work_dir/cargo-target" \
    "$work_dir/home" \
    "$work_dir/src"

run_args=(run --rm --network=host)
if [[ "$container_engine" == podman ]]; then
    run_args+=(--userns=keep-id --security-opt label=disable)
else
    run_args+=(--user "$(id -u):$(id -g)")
fi
run_args+=(
    --env HOME=/work/home
    --env CARGO_HOME=/work/cargo-home
    --env CARGO_TARGET_DIR=/work/cargo-target
    --env "ALACRITTY_VERSION=$alacritty_version"
    --env "ALACRITTY_COMMIT=$alacritty_commit"
    --volume "$script_dir:/source:ro"
    --volume "$work_dir:/work"
    "$builder_image"
    /source/tools/static-alacritty/build-inside.sh
)

printf 'Compiling official Alacritty v%s in CentOS 7 ...\n' "$alacritty_version"
"$container_engine" "${run_args[@]}"

container_artifact="$work_dir/artifacts/alacritty-onefile"
[[ -x "$container_artifact" ]] || die 'the container did not produce an executable'
install -m 0755 -- "$container_artifact" "$output_path"

if readelf -lW "$output_path" | grep -q ' INTERP '; then
    die 'the outer launcher unexpectedly contains a dynamic interpreter'
fi
if readelf -dW "$output_path" 2>/dev/null | grep -q '(NEEDED)'; then
    die 'the outer launcher unexpectedly contains dynamic dependencies'
fi

version_output="$($output_path --version)"
expected_version_output="alacritty $alacritty_version (${alacritty_commit:0:7})"
[[ "$version_output" == "$expected_version_output" ]] ||
    die "unexpected version output: $version_output"

sha256="$(sha256sum "$output_path" | awk '{print $1}')"
size="$(du -h "$output_path" | awk '{print $1}')"
printf '\nBuilt: %s\nSize: %s\nSHA-256: %s\n' "$output_path" "$size" "$sha256"
printf 'Verification: static outer ELF; bundled CentOS 7 payload; host X/GL required.\n'
