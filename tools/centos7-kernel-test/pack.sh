#!/bin/bash
set -euo pipefail
cp /boot/vmlinuz-3.10.0-1160.el7.x86_64 /out/vmlinuz
cp /out/init /init
chmod 755 /init
cp /artifact /opt/alacritty
cd /
find . -path ./proc -prune -o -path ./sys -prune -o -path ./dev -prune -o -path ./out -prune -o -path ./artifact -prune -o -path ./usr/lib/firmware -prune -o -path ./boot -prune -o -path ./var/cache -prune -o -print0 | cpio --null -o -H newc | gzip -1 >/out/initramfs.cpio.gz
