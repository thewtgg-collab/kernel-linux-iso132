#!/usr/bin/env bash
set -euo pipefail

# Build a minimal Linux ISO from pristine upstream sources.
# Builds and generated configs are kept outside the kernel source tree.
KERNEL_VERSION="${KERNEL_VERSION:-6.12.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${ROOT}/work"
SRC="${WORK}/linux-${KERNEL_VERSION}"
OUT="${WORK}/kernel-build"
ISO="${WORK}/iso"
INITRD="${WORK}/initrd"
JOBS="${JOBS:-2}"

for cmd in curl tar make gcc cpio gzip grub-mkrescue xorriso loadkeys; do
  command -v "$cmd" >/dev/null || { echo "Missing build tool: $cmd" >&2; exit 1; }
done
BUSYBOX="$(command -v busybox || true)"
[ -n "$BUSYBOX" ] || { echo "Install busybox-static" >&2; exit 1; }
# Static PIE binaries can be misreported by ldd. Check the ELF
# program headers instead: a static binary has no PT_INTERP loader.
if readelf -l "$BUSYBOX" | grep -q 'INTERP'; then
  echo "BusyBox requires a dynamic ELF loader: $BUSYBOX" >&2
  exit 1
fi
echo "Static BusyBox available: $BUSYBOX"

mkdir -p "$WORK"
ARCHIVE="$WORK/linux-${KERNEL_VERSION}.tar.xz"
if [ ! -d "$SRC" ]; then
  curl -fL --retry 3 -o "$ARCHIVE" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
  tar -xJf "$ARCHIVE" -C "$WORK"
fi

mkdir -p "$OUT" "$ISO/boot/grub" "$INITRD"/{bin,sbin,etc,proc,sys,dev,tmp,root}
make -C "$SRC" O="$OUT" ARCH=x86_64 x86_64_defconfig
make -C "$SRC" O="$OUT" ARCH=x86_64 -j"$JOBS" bzImage
cp "$OUT/arch/x86/boot/bzImage" "$ISO/boot/vmlinuz"

# Generate a Hungarian keyboard binary map; Linux kernel source remains pristine.
if ! "$BUSYBOX" --list | grep -qx loadkmap; then
  echo "BusyBox has no loadkmap applet" >&2
  exit 1
fi
loadkeys -b hu > "$INITRD/etc/hu.bmap"
test -s "$INITRD/etc/hu.bmap"
# Minimal root account database for BusyBox id/whoami/getent.
# This changes the initramfs only, never the upstream kernel.
printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' > "$INITRD/etc/passwd"
printf '%s\n' 'root:x:0:' > "$INITRD/etc/group"
chmod 644 "$INITRD/etc/passwd" "$INITRD/etc/group"
cp "$BUSYBOX" "$INITRD/bin/busybox"
ln -sf busybox "$INITRD/bin/sh"
cat > "$INITRD/init" <<'INIT'
#!/bin/sh
export PATH=/bin:/sbin
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox loadkmap < /etc/hu.bmap || echo "Could not load Hungarian keyboard map"
clear
echo ""
echo "========================================"
echo "    Kernel Linux - minimal live ISO"
echo "========================================"
uname -a
echo ""
echo "BusyBox shell ready. Try: ls, uname -a, cat /proc/cpuinfo"
echo "To power off: poweroff -f"
echo ""
exec /bin/sh </dev/console >/dev/console 2>&1
INIT
chmod +x "$INITRD/init"
cat > "$ISO/boot/grub/grub.cfg" <<'GRUB'
set timeout=2
set default=0
menuentry "Kernel Linux (unmodified upstream kernel)" {
    linux /boot/vmlinuz console=tty0 rdinit=/init
    initrd /boot/initramfs.cpio.gz
}
GRUB
(
  cd "$INITRD"
  find . -print0 | cpio --null -o --format=newc | gzip -9 > "$ISO/boot/initramfs.cpio.gz"
)
grub-mkrescue -o "$ROOT/kernel-linux.iso" "$ISO"
echo "ISO created: $ROOT/kernel-linux.iso"
