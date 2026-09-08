#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
#             MikroTik CHR Easy Installer v5
#                      by Ramin TR
# ============================================================
# One-command / one-number CHR installer for Ubuntu/Debian VPS.
# Selecting a version starts the full installation automatically.
# WARNING: installation permanently erases the detected system disk.

C="\033[1;36m"; G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; N="\033[0m"
info(){ echo -e "${C}[INFO]${N} $*"; }
ok(){ echo -e "${G}[OK]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
die(){ echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || die "Run as root."

# Current approved versions for this installer.
ROS7="7.24.2"
ROS6="6.49.21"

clear 2>/dev/null || true
cat <<'EOF'
============================================================
             MikroTik CHR Easy Installer v5
                      by Ramin TR
============================================================
     Auto-detect -> choose 1 number -> full installation
============================================================
EOF

for c in lsblk findmnt awk grep df ip dd sha256sum sync; do
  have "$c" || die "Required base command missing: $c"
done

ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[[ "$ROOT_SRC" == /dev/* ]] && ROOT_SRC="$(readlink -f "$ROOT_SRC" 2>/dev/null || echo "$ROOT_SRC")"

TARGET=""
cur="$ROOT_SRC"
for _ in {1..10}; do
  [[ "$cur" == /dev/* ]] || break
  typ="$(lsblk -ndo TYPE "$cur" 2>/dev/null | head -1 || true)"
  if [[ "$typ" == "disk" ]]; then TARGET="$cur"; break; fi
  parent="$(lsblk -ndo PKNAME "$cur" 2>/dev/null | head -1 || true)"
  [[ -n "$parent" ]] || break
  cur="/dev/$parent"
done

mapfile -t DISKS < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}')
if [[ -z "$TARGET" && ${#DISKS[@]} -eq 1 ]]; then TARGET="${DISKS[0]}"; fi
[[ -b "$TARGET" ]] || die "Could not safely identify the system disk. No changes made."

IPV4="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $4}' || true)"
GW="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $3}' || true)"
NIC="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}' || true)"
MAC=""
[[ -n "$NIC" && -r "/sys/class/net/$NIC/address" ]] && MAC="$(cat "/sys/class/net/$NIC/address")"

NETMODE="UNKNOWN"
if ip -4 route show default 2>/dev/null | grep -qw dhcp; then
  NETMODE="DHCP"
elif ip -4 route show default 2>/dev/null | grep -qw static; then
  NETMODE="STATIC"
elif have networkctl && [[ -n "$NIC" ]] && networkctl status "$NIC" 2>/dev/null | grep -qi "DHCP4.*yes"; then
  NETMODE="DHCP"
fi

VIRT="Unknown"
if have systemd-detect-virt; then
  VIRT="$(systemd-detect-virt 2>/dev/null || true)"
  [[ -z "$VIRT" || "$VIRT" == "none" ]] && VIRT="Bare-metal/Unknown"
fi

RAM_MB="$(awk '/MemTotal/{printf "%.0f",$2/1024}' /proc/meminfo)"
CPU_COUNT="$(nproc 2>/dev/null || echo "?")"
DISK_SIZE="$(lsblk -ndo SIZE "$TARGET" | head -1)"

echo
echo "Detected:"
echo "  Virtualization : $VIRT"
echo "  CPU            : $CPU_COUNT vCPU"
echo "  RAM            : ${RAM_MB} MB"
echo "  System disk    : $TARGET ($DISK_SIZE)"
echo "  IPv4           : ${IPV4:-unknown}"
echo "  Gateway        : ${GW:-unknown}"
echo "  NIC / MAC      : ${NIC:-unknown} / ${MAC:-unknown}"
echo "  Network mode   : $NETMODE"
echo

echo "Choose RouterOS version:"
echo
echo -e "  ${G}1) RouterOS 7.24.2  [RECOMMENDED]${N}"
echo "     Best choice for modern CHR, WireGuard and current security."
echo
echo -e "  ${Y}2) RouterOS 6.49.21 [LEGACY / WARNING]${N}"
echo "     Use only for legacy compatibility. No WireGuard support."
echo "     RouterOS v6 is no longer the preferred branch."
echo
echo "  0) Cancel"
echo

if [[ "$NETMODE" == "STATIC" || "$NETMODE" == "UNKNOWN" ]]; then
  warn "Network is not confirmed DHCP."
  warn "After CHR boots, static IP/Gateway may need provider-console configuration."
  echo
fi

warn "Selecting 1 or 2 starts installation and WILL ERASE ALL DATA on $TARGET."
read -rp "Select [1/2/0]: " CHOICE

case "$CHOICE" in
  1) VERSION="$ROS7" ;;
  2) VERSION="$ROS6" ;;
  0) echo "Cancelled."; exit 0 ;;
  *) die "Invalid selection." ;;
esac

echo
info "Selected RouterOS $VERSION. Automatic installation started."

have apt-get || die "apt-get is required for automatic Ubuntu/Debian installation."
export DEBIAN_FRONTEND=noninteractive

info "Updating Ubuntu package indexes and installed packages..."
apt-get update
apt-get -y upgrade

PKGS=()
have curl || PKGS+=(curl)
have unzip || PKGS+=(unzip)
if ((${#PKGS[@]})); then
  info "Installing required tools: ${PKGS[*]}"
  apt-get install -y "${PKGS[@]}"
fi

RAMDIR="/dev/shm/chr-easy-installer"
mkdir -p "$RAMDIR"
ZIP="$RAMDIR/chr-${VERSION}.img.zip"
IMG="$RAMDIR/chr-${VERSION}.img"
URL="https://download.mikrotik.com/routeros/${VERSION}/chr-${VERSION}.img.zip"

FREE_KB="$(df -Pk /dev/shm | awk 'NR==2{print $4}')"
[[ "${FREE_KB:-0}" -gt 524288 ]] || die "/dev/shm needs at least 512 MiB free."

info "Downloading official MikroTik CHR $VERSION..."
rm -f "$ZIP" "$IMG"
curl -fL --retry 3 --connect-timeout 15 -o "$ZIP" "$URL"

info "Verifying downloaded archive..."
unzip -t "$ZIP" >/dev/null || die "Downloaded archive failed integrity test."

info "Extracting image to RAM..."
unzip -jo "$ZIP" "chr-${VERSION}.img" -d "$RAMDIR" >/dev/null
[[ -s "$IMG" ]] || die "CHR image extraction failed."

HASH="$(sha256sum "$IMG" | awk '{print $1}')"
ok "Image ready."
echo "SHA256: $HASH"

have swapoff && swapoff -a 2>/dev/null || true
sync

info "Installing MikroTik CHR $VERSION on $TARGET..."
dd if="$IMG" of="$TARGET" bs=4M conv=fsync status=progress

ok "CHR installation completed."
echo
echo "Previous network details for reference:"
echo "  IPv4    : ${IPV4:-unknown}"
echo "  Gateway : ${GW:-unknown}"
echo "  NIC/MAC : ${NIC:-unknown} / ${MAC:-unknown}"
echo
info "Rebooting into MikroTik CHR..."
sleep 3

if [[ -w /proc/sysrq-trigger ]]; then
  echo b > /proc/sysrq-trigger
fi

reboot -f
