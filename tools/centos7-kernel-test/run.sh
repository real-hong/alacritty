#!/usr/bin/env bash
# Full-system test: no KVM or host display required. Needs Podman and downloads
# CentOS 7/QEMU packages on the first build.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "$script_dir/../.." && pwd -P)"
work_dir="$project_dir/build/centos7-kernel-test"
artifact="${1:-$project_dir/build/static-alacritty/alacritty-onefile-0.17.0-x86_64}"
artifact="$(realpath -- "$artifact")"
[[ -x "$artifact" ]]
mkdir -p "$work_dir"
cp "$script_dir/init" "$script_dir/pack.sh" "$work_dir/"
podman build --network=host -t localhost/alacritty-centos7-kernel-test -f "$script_dir/Containerfile.guest" "$script_dir"
podman build --network=host -t localhost/alacritty-qemu-test -f "$script_dir/Containerfile.qemu" "$script_dir"
podman run --rm --network=none --security-opt label=disable \
    -v "$work_dir:/out" -v "$artifact:/artifact:ro" \
    localhost/alacritty-centos7-kernel-test bash /out/pack.sh
timeout 300 podman run --rm --network=none --security-opt label=disable \
    -v "$work_dir:/test:ro" localhost/alacritty-qemu-test \
    -accel tcg -cpu qemu64 -m 2048 -smp 2 -display none -monitor none \
    -serial stdio -no-reboot -nic none -device virtio-rng-pci \
    -kernel /test/vmlinuz -initrd /test/initramfs.cpio.gz \
    -append 'console=ttyS0 rdinit=/init panic=-1' 2>&1 | tee "$work_dir/serial.log"
grep -q NATIVE_KERNEL_GUI_TEST_PASS "$work_dir/serial.log"
