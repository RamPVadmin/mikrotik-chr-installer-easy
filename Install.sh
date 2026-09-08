#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
#             MikroTik CHR Easy Installer v4
#                      by Ramin TR
# ============================================================
# One-command automatic CHR installer for Ubuntu/Debian VPS.
# WARNING: Installation permanently erases the selected system disk.

C="\033[1;36m"; G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; N="\033[0m"
info(){ echo -e "${C}[INFO]${N} $*"; }
ok(){ echo -e "${G}[OK]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
die(){ echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || die "Run as root."

clear 2>/dev/null || true
cat <<'EOF'
============================================================
             MikroTik CHR Easy Installer v4
                      by Ramin TR
============================================================
      Automatic detection, download and installation
============================================================
EOF

# Read-only preflight.
for c in lsblk findmnt awk grep df ip dd sha256sum sync; do
  have "$c" || die "Required base command missing: $c"
done

ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[[ "$ROOT_SRC" == /dev/* ]] && ROOT_SRC="$(readlink -f "$ROOT_SRC" 2>/dev/null || echo "$ROOT_SRC")"

# Walk from root filesystem through partitions/LVM/DM to physical disk.
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

# Best-effort DHCP/static detection without changing network.
NETMODE="UNKNOWN"
if ip -4 route show default 2>/dev/null | grep -qw dhcp; then
  NETMODE="DHCP"
elif ip -4 route show default 2>/dev/null | grep -qw static; then
  NETMODE="STATIC"
elif have networkctl && networkctl status "$NIC" 2>/dev/null | grep -qi "DHCP4.*yes"; then
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

# Recommendation: modern ROS7 for CHR; WireGuard requires ROS7.
# Stable is default; user can change DEFAULT_VERSION in GitHub when desired.
DEFAULT_VERSION="7.24.2"
RECOMMENDED="$DEFAULT_VERSION"

echo
echo "Detected automatically:"
echo "  Virtualization : $VIRT"
echo "  CPU            : $CPU_COUNT vCPU"
echo "  RAM            : ${RAM_MB} MB"
echo "  System disk    : $TARGET ($DISK_SIZE)"
echo "  IPv4           : ${IPV4:-unknown}"
echo "  Gateway        : ${GW:-unknown}"
echo "  NIC / MAC      : ${NIC:-unknown} / ${MAC:-unknown}"
echo "  Network mode   : $NETMODE"
echo
echo "Recommended CHR  : RouterOS $RECOMMENDED"
echo

if [[ "$NETMODE" == "STATIC" || "$NETMODE" == "UNKNOWN" ]]; then
  warn "This VPS does not appear to use confirmed DHCP."
  warn "CHR may require IP/Gateway configuration from provider console after boot."
fi

echo "The installer will:"
echo "  1. Update Ubuntu package indexes/packages"
echo "  2. Install only missing download/extract tools"
echo "  3. Download official MikroTik CHR $RECOMMENDED"
echo "  4. Extract the image into RAM"
echo "  5. Erase $TARGET and install CHR"
echo "  6. Reboot automatically"
echo
warn "ALL DATA ON $TARGET WILL BE PERMANENTLY ERASED."
echo
read -rp "Press ENTER to install, or type NO to cancel: " ANSWER
[[ "${ANSWER^^}" != "NO" ]] || { echo "Cancelled."; exit 0; }

# From here installation was explicitly approved.
have apt-get || die "apt-get not available. This automatic mode supports Ubuntu/Debian."
info "Updating Ubuntu..."
export DEBIAN_FRONTEND=noninteractive
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
ZIP="$RAMDIR/chr-${RECOMMENDED}.img.zip"
IMG="$RAMDIR/chr-${RECOMMENDED}.img"
URL="https://download.mikrotik.com/routeros/${RECOMMENDED}/chr-${RECOMMENDED}.img.zip"

FREE_KB="$(df -Pk /dev/shm | awk 'NR==2{print $4}')"
[[ "${FREE_KB:-0}" -gt 524288 ]] || die "/dev/shm needs at least 512 MiB free."

info "Downloading official MikroTik CHR $RECOMMENDED..."
rm -f "$ZIP" "$IMG"
curl -fL --retry 3 --connect-timeout 15 -o "$ZIP" "$URL"

info "Checking archive..."
unzip -t "$ZIP" >/dev/null || die "Downloaded archive failed integrity test."

info "Extracting CHR image to RAM..."
unzip -jo "$ZIP" "chr-${RECOMMENDED}.img" -d "$RAMDIR" >/dev/null
[[ -s "$IMG" ]] || die "CHR image extraction failed."

HASH="$(sha256sum "$IMG" | awk '{print $1}')"
ok "Image ready."
echo "SHA256: $HASH"
echo
warn "LAST CONFIRMATION: $TARGET WILL NOW BE ERASED."
read -rp "Type YES to continue: " FINAL
[[ "${FINAL^^}" == "YES" ]] || { echo "Cancelled before disk write."; exit 0; }

have swapoff && swapoff -a 2>/dev/null || true
sync

info "Installing MikroTik CHR $RECOMMENDED on $TARGET..."
dd if="$IMG" of="$TARGET" bs=4M conv=fsync status=progress

ok "CHR installation completed."
echo "Previous Linux network for reference:"
echo "  IPv4: ${IPV4:-unknown}"
echo "  Gateway: ${GW:-unknown}"
echo "  MAC: ${MAC:-unknown}"
info "Rebooting into MikroTik CHR..."
sleep 3

if [[ -w /proc/sysrq-trigger ]]; then
  echo b > /proc/sysrq-trigger
fi
reboot -f
