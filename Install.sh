#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
#          MikroTik CHR Direct Installer v2
#                    by Ramin TR
# ============================================================

C="\033[1;36m"; G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; N="\033[0m"
info(){ echo -e "${C}[INFO]${N} $*"; }
ok(){ echo -e "${G}[OK]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*"; }
die(){ echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"

clear || true
cat <<'EOF'
============================================================
          MikroTik CHR Direct Installer v2
                    by Ramin TR
============================================================
EOF

command -v curl >/dev/null || die "curl required"
command -v unzip >/dev/null || apt-get update && apt-get install -y unzip

ROOT_SRC="$(findmnt -n -o SOURCE /)"
ROOT_SRC="$(readlink -f "$ROOT_SRC" 2>/dev/null || echo "$ROOT_SRC")"

DISK=""
CUR="$ROOT_SRC"

for i in {1..10}; do
    TYPE="$(lsblk -ndo TYPE "$CUR" 2>/dev/null | head -1 || true)"
    if [[ "$TYPE" == "disk" ]]; then
        DISK="$CUR"
        break
    fi
    PARENT="$(lsblk -ndo PKNAME "$CUR" 2>/dev/null | head -1 || true)"
    [[ -n "$PARENT" ]] || break
    CUR="/dev/$PARENT"
done

[[ -b "$DISK" ]] || die "Cannot detect system disk"

IP="$(ip -4 -o addr show scope global | awk 'NR==1{print $4}')"
GW="$(ip route | awk '/default/{print $3; exit}')"
NIC="$(ip route | awk '/default/{print $5; exit}')"
MAC="$(cat /sys/class/net/$NIC/address 2>/dev/null || true)"

echo
echo "Detected:"
echo "Disk     : $DISK"
echo "IP       : $IP"
echo "Gateway  : $GW"
echo "NIC/MAC  : $NIC / $MAC"
echo

echo "Choose CHR version:"
echo "1) RouterOS 7.24.2 Stable"
echo "2) RouterOS 7.23.5 Long-term"
echo "3) RouterOS 6.49.21 Stable"
echo "4) RouterOS 6.49.21 Long-term"
echo

read -rp "Select: " CH

case "$CH" in
1) VER="7.24.2" ;;
2) VER="7.23.5" ;;
3|4) VER="6.49.21" ;;
*) die "Invalid selection" ;;
esac

warn "THIS WILL ERASE $DISK"
read -rp "Type INSTALL: " OK
[[ "$OK" == "INSTALL" ]] || exit 0

WORK=/tmp/chr-direct
mkdir -p "$WORK"

URL="https://download.mikrotik.com/routeros/$VER/chr-$VER.img.zip"

info "Downloading CHR $VER..."
curl -fL --retry 8 --retry-all-errors -o "$WORK/chr.zip" "$URL"

info "Extracting..."
unzip -o "$WORK/chr.zip" -d "$WORK"

IMG="$WORK/chr-$VER.img"
[[ -f "$IMG" ]] || die "Image not found"

ok "Image ready"
sha256sum "$IMG"

sync
warn "Writing CHR to $DISK..."

dd if="$IMG" of="$DISK" bs=4M conv=fsync status=progress

sync

ok "CHR installed"

echo
echo "First login:"
echo "Username: admin"
echo "Password: empty"

echo
echo "Previous network:"
echo "IP: $IP"
echo "Gateway: $GW"
echo "MAC: $MAC"

sleep 3
reboot -f
