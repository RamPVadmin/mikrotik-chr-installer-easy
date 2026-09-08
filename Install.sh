#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
#             MikroTik CHR Easy Installer v6
#                      by Ramin TR
# ============================================================
# CHR x86_64 only. Ubuntu/Debian VPS -> official MikroTik CHR.
# Select one number; the rest is automatic.
# WARNING: a successful installation erases the detected system disk.

C="\033[1;36m"; G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; B="\033[1m"; N="\033[0m"
info(){ echo -e "${C}[INFO]${N} $*"; }
ok(){ echo -e "${G}[OK]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
die(){ echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || die "Run as root."

clear 2>/dev/null || true
cat <<'EOF'
============================================================
             MikroTik CHR Easy Installer v6
                      by Ramin TR
============================================================
              CHR x86_64 ONLY
       Auto-detect -> choose -> auto-install
============================================================
EOF

for c in lsblk findmnt awk grep df ip dd sha256sum sync; do
  have "$c" || die "Required base command missing: $c"
done

# ---------- Detect system disk ----------
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[[ "$ROOT_SRC" == /dev/* ]] && ROOT_SRC="$(readlink -f "$ROOT_SRC" 2>/dev/null || echo "$ROOT_SRC")"

TARGET=""
cur="$ROOT_SRC"
for _ in {1..10}; do
  [[ "$cur" == /dev/* ]] || break
  typ="$(lsblk -ndo TYPE "$cur" 2>/dev/null | head -1 || true)"
  [[ "$typ" == "disk" ]] && { TARGET="$cur"; break; }
  parent="$(lsblk -ndo PKNAME "$cur" 2>/dev/null | head -1 || true)"
  [[ -n "$parent" ]] || break
  cur="/dev/$parent"
done

mapfile -t DISKS < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}')
[[ -z "$TARGET" && ${#DISKS[@]} -eq 1 ]] && TARGET="${DISKS[0]}"
[[ -b "$TARGET" ]] || die "Could not safely identify system disk. Nothing changed."

# ---------- Detect network / platform ----------
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

# ---------- Candidate CHR x86_64 versions ----------
# Curated production/legacy choices. Each URL is checked live before selection.
VERSIONS=("7.24.2" "7.23.5" "6.49.21")
LABELS=("STABLE / RECOMMENDED" "LONG-TERM / RECOMMENDED" "LEGACY / WARNING")
AVAILABLE=()

# Network check uses curl/wget if already present; it does NOT apt-install before selection.
url_exists() {
  local u="$1"
  if have curl; then
    curl -fsIL --connect-timeout 7 --max-time 12 "$u" >/dev/null 2>&1
  elif have wget; then
    wget --spider -q -T 12 "$u" >/dev/null 2>&1
  else
    return 2
  fi
}

echo "Official CHR x86_64 choices:"
echo
for i in "${!VERSIONS[@]}"; do
  v="${VERSIONS[$i]}"
  u="https://download.mikrotik.com/routeros/$v/chr-$v.img.zip"
  status="${LABELS[$i]}"
  if url_exists "$u"; then
    AVAILABLE[$i]=1
    if [[ "$v" == 6.* ]]; then
      echo -e "  $((i+1))) RouterOS $v  ${Y}[$status]${N}"
      echo "     CHR x86_64 image: AVAILABLE | No WireGuard"
    else
      echo -e "  $((i+1))) RouterOS $v  ${G}[$status]${N}"
      echo "     CHR x86_64 image: AVAILABLE | WireGuard supported"
    fi
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then
      AVAILABLE[$i]=1
      echo -e "  $((i+1))) RouterOS $v  [$status] ${Y}[URL CHECK DEFERRED]${N}"
    else
      AVAILABLE[$i]=0
      echo -e "  $((i+1))) RouterOS $v  ${R}[NOT AVAILABLE / WARNING]${N}"
      echo "     Official CHR image was not found; selection is blocked."
    fi
  fi
  echo
done
echo "  0) Cancel"
echo

[[ "$NETMODE" == "STATIC" || "$NETMODE" == "UNKNOWN" ]] && {
  warn "Network is not confirmed DHCP."
  warn "Static IP/Gateway may require provider-console configuration after CHR boots."
  echo
}

warn "Selecting an available version starts the full installation automatically."
warn "Successful installation WILL ERASE ALL DATA on $TARGET."
read -rp "Select version number: " CHOICE

[[ "$CHOICE" =~ ^[0-9]+$ ]] || die "Invalid selection."
[[ "$CHOICE" != "0" ]] || { echo "Cancelled."; exit 0; }
idx=$((CHOICE-1))
(( idx >= 0 && idx < ${#VERSIONS[@]} )) || die "Invalid selection."
[[ "${AVAILABLE[$idx]:-0}" == "1" ]] || die "This CHR version is marked NOT AVAILABLE."

VERSION="${VERSIONS[$idx]}"
URL="https://download.mikrotik.com/routeros/$VERSION/chr-$VERSION.img.zip"

echo
info "Selected official CHR x86_64 RouterOS $VERSION."
info "Automatic installation started."

# ---------- Update Ubuntu and install only required helpers ----------
have apt-get || die "apt-get is required for automatic Ubuntu/Debian mode."
export DEBIAN_FRONTEND=noninteractive

info "Updating Ubuntu/Debian..."
apt-get update
apt-get -y upgrade

PKGS=()
have curl || PKGS+=(curl)
have unzip || PKGS+=(unzip)
if ((${#PKGS[@]})); then
  info "Installing missing tools: ${PKGS[*]}"
  apt-get install -y "${PKGS[@]}"
fi

# Re-check exact official CHR image after curl is guaranteed.
info "Confirming official CHR image availability..."
curl -fsIL --connect-timeout 10 --max-time 20 "$URL" >/dev/null \
  || die "Official CHR image is unavailable. Disk has NOT been written."

# ---------- Download / verify / extract to RAM ----------
RAMDIR="/dev/shm/chr-easy-installer"
mkdir -p "$RAMDIR"
ZIP="$RAMDIR/chr-${VERSION}.img.zip"
IMG="$RAMDIR/chr-${VERSION}.img"

FREE_KB="$(df -Pk /dev/shm | awk 'NR==2{print $4}')"
[[ "${FREE_KB:-0}" -gt 524288 ]] || die "/dev/shm needs at least 512 MiB free."

info "Downloading from MikroTik..."
rm -f "$ZIP" "$IMG"
curl -fL --retry 3 --connect-timeout 15 -o "$ZIP" "$URL"

info "Testing ZIP integrity..."
unzip -t "$ZIP" >/dev/null || die "Downloaded archive failed integrity test."

info "Extracting CHR image to RAM..."
unzip -jo "$ZIP" "chr-${VERSION}.img" -d "$RAMDIR" >/dev/null
[[ -s "$IMG" ]] || die "CHR image extraction failed."

HASH="$(sha256sum "$IMG" | awk '{print $1}')"
ok "Official CHR image is ready."
echo "  Version : $VERSION"
echo "  SHA256  : $HASH"
echo "  Target  : $TARGET"
echo

# The version number selection was the user's destructive-operation confirmation.
have swapoff && swapoff -a 2>/dev/null || true
sync

info "Writing CHR x86_64 RouterOS $VERSION to $TARGET..."
dd if="$IMG" of="$TARGET" bs=4M conv=fsync status=progress

ok "MikroTik CHR installation completed."
echo
echo "Previous network details:"
echo "  IPv4    : ${IPV4:-unknown}"
echo "  Gateway : ${GW:-unknown}"
echo "  NIC/MAC : ${NIC:-unknown} / ${MAC:-unknown}"
echo
info "Rebooting into CHR..."
sleep 3

if [[ -w /proc/sysrq-trigger ]]; then
  echo b > /proc/sysrq-trigger
fi
reboot -f
