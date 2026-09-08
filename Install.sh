#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
#             MikroTik CHR Easy Installer v7
#                      by Ramin TR
# ============================================================
# CHR x86_64 only
# Shows official RouterOS 6/7 Stable + Long-term releases,
# verifies the selected CHR image, then installs automatically.
#
# PRIORITY: preserve VPS reachability.
# IMPORTANT: a raw CHR install cannot universally guarantee that
# a provider's STATIC Linux IP configuration will survive first boot.
# DHCP/MAC-bound networks are normally safer. Static networks are
# clearly marked with an IP-RISK warning before selection.
#
# WARNING: selecting a version starts the destructive installation.

C="\033[1;36m"
G="\033[1;32m"
Y="\033[1;33m"
R="\033[1;31m"
B="\033[1m"
N="\033[0m"

info(){ echo -e "${C}[INFO]${N} $*"; }
ok(){ echo -e "${G}[OK]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
die(){ echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || die "Run as root."

clear 2>/dev/null || true
cat <<'EOF'
================================================================
               MikroTik CHR Easy Installer v7
                        by Ramin TR
================================================================
                 CHR x86_64 ONLY
      Detect network -> choose version -> auto-install
================================================================
EOF

for c in lsblk findmnt awk grep df ip dd sha256sum sync sort sed; do
  have "$c" || die "Required base command missing: $c"
done

# ---------- Detect system disk ----------
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
if [[ "$ROOT_SRC" == /dev/* ]] && have readlink; then
  ROOT_SRC="$(readlink -f "$ROOT_SRC" 2>/dev/null || echo "$ROOT_SRC")"
fi

TARGET=""
cur="$ROOT_SRC"
for _ in {1..10}; do
  [[ "$cur" == /dev/* ]] || break
  typ="$(lsblk -ndo TYPE "$cur" 2>/dev/null | head -1 || true)"
  if [[ "$typ" == "disk" ]]; then
    TARGET="$cur"
    break
  fi
  parent="$(lsblk -ndo PKNAME "$cur" 2>/dev/null | head -1 || true)"
  [[ -n "$parent" ]] || break
  cur="/dev/$parent"
done

mapfile -t PHYSICAL_DISKS < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}')
if [[ -z "$TARGET" && ${#PHYSICAL_DISKS[@]} -eq 1 ]]; then
  TARGET="${PHYSICAL_DISKS[0]}"
fi
[[ -b "$TARGET" ]] || die "Could not safely identify the system disk. Nothing changed."

# ---------- Detect network ----------
IPV4="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $4}' || true)"
GW="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $3}' || true)"
NIC="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}' || true)"
MAC=""
[[ -n "$NIC" && -r "/sys/class/net/$NIC/address" ]] && MAC="$(cat "/sys/class/net/$NIC/address")"

NETMODE="UNKNOWN"
DEFAULT_ROUTE="$(ip -4 route show default 2>/dev/null | head -1 || true)"
if grep -qw dhcp <<<"$DEFAULT_ROUTE"; then
  NETMODE="DHCP"
elif grep -qw static <<<"$DEFAULT_ROUTE"; then
  NETMODE="STATIC"
elif have networkctl && [[ -n "$NIC" ]]; then
  if networkctl status "$NIC" 2>/dev/null | grep -Eqi 'DHCP4.*yes|DHCP.*yes'; then
    NETMODE="DHCP"
  fi
fi

VIRT="Unknown"
if have systemd-detect-virt; then
  VIRT="$(systemd-detect-virt 2>/dev/null || true)"
  [[ -z "$VIRT" || "$VIRT" == "none" ]] && VIRT="Bare-metal/Unknown"
fi

RAM_MB="$(awk '/MemTotal/{printf "%.0f",$2/1024}' /proc/meminfo)"
CPU_COUNT="$(nproc 2>/dev/null || echo "?")"
DISK_SIZE="$(lsblk -ndo SIZE "$TARGET" | head -1)"

if [[ "$NETMODE" == "DHCP" ]]; then
  IP_STATUS="PING-SAFE-LIKELY"
  IP_COLOR="$G"
else
  IP_STATUS="IP-RISK"
  IP_COLOR="$Y"
fi

echo
echo "Detected VPS:"
echo "  Virtualization : $VIRT"
echo "  CPU            : $CPU_COUNT vCPU"
echo "  RAM            : ${RAM_MB} MB"
echo "  System disk    : $TARGET ($DISK_SIZE)"
echo "  IPv4           : ${IPV4:-unknown}"
echo "  Gateway        : ${GW:-unknown}"
echo "  NIC / MAC      : ${NIC:-unknown} / ${MAC:-unknown}"
echo "  Network mode   : $NETMODE"
echo -e "  Ping status    : ${IP_COLOR}${IP_STATUS}${N}"
echo

# ---------- Obtain curl/wget for read-only discovery ----------
# Do NOT apt-install anything before user chooses a version.
FETCH=""
if have curl; then FETCH="curl"; elif have wget; then FETCH="wget"; fi

fetch_page() {
  local url="$1"
  if [[ "$FETCH" == "curl" ]]; then
    curl -fsSL --connect-timeout 10 --max-time 25 "$url"
  elif [[ "$FETCH" == "wget" ]]; then
    wget -qO- -T 25 "$url"
  else
    return 2
  fi
}

url_exists() {
  local u="$1"
  if have curl; then
    curl -fsIL --connect-timeout 6 --max-time 10 "$u" >/dev/null 2>&1
  elif have wget; then
    wget --spider -q -T 10 "$u" >/dev/null 2>&1
  else
    return 2
  fi
}

# ---------- Discover Stable + Long-term ROS6/ROS7 ----------
declare -A CHANNEL
declare -a VERSIONS

extract_versions() {
  # Keeps final releases only; excludes beta/rc/development strings.
  grep -Eo '(^|[^0-9])([67]\.[0-9]+(\.[0-9]+)?)([^0-9A-Za-z]|$)' \
  | grep -Eo '[67]\.[0-9]+(\.[0-9]+)?' \
  | sort -Vu
}

add_versions() {
  local label="$1"
  shift
  local v
  for v in "$@"; do
    [[ "$v" =~ ^[67]\.[0-9]+(\.[0-9]+)?$ ]] || continue
    if [[ -z "${CHANNEL[$v]:-}" ]]; then
      VERSIONS+=("$v")
      CHANNEL["$v"]="$label"
    elif [[ "${CHANNEL[$v]}" != *"$label"* ]]; then
      CHANNEL["$v"]="${CHANNEL[$v]}+$label"
    fi
  done
}

if [[ -n "$FETCH" ]]; then
  STABLE_HTML="$(fetch_page 'https://mikrotik.com/download/changelogs?channelFilter=stable' 2>/dev/null || true)"
  LONG_HTML="$(fetch_page 'https://mikrotik.com/download/changelogs?channelFilter=long-term' 2>/dev/null || true)"

  if [[ -n "$STABLE_HTML" ]]; then
    mapfile -t SVER < <(printf '%s' "$STABLE_HTML" | extract_versions)
    add_versions "STABLE" "${SVER[@]}"
  fi
  if [[ -n "$LONG_HTML" ]]; then
    mapfile -t LVER < <(printf '%s' "$LONG_HTML" | extract_versions)
    add_versions "LONG-TERM" "${LVER[@]}"
  fi
fi

# Fallback if MikroTik page parsing is unavailable.
if ((${#VERSIONS[@]} == 0)); then
  warn "Could not dynamically read MikroTik release list; using built-in fallback list."
  FALLBACK=(
    "7.24.2:STABLE"
    "7.24.1:STABLE"
    "7.24:STABLE"
    "7.23.5:LONG-TERM"
    "7.23.4:LONG-TERM"
    "7.21.5:LONG-TERM"
    "7.20.8:LONG-TERM"
    "6.49.21:STABLE+LONG-TERM"
    "6.49.20:STABLE+LONG-TERM"
    "6.49.19:STABLE+LONG-TERM"
    "6.48.7:LONG-TERM"
    "6.48.6:LONG-TERM"
  )
  for item in "${FALLBACK[@]}"; do
    v="${item%%:*}"
    ch="${item#*:}"
    VERSIONS+=("$v")
    CHANNEL["$v"]="$ch"
  done
fi

# Newest first, keeping only ROS6/7 final releases.
mapfile -t SORTED < <(printf '%s\n' "${VERSIONS[@]}" | sort -Vru)
VERSIONS=("${SORTED[@]}")

echo "Official RouterOS Stable / Long-term CHR x86_64:"
echo
echo "  #   VERSION       CHANNEL               NETWORK"
echo "  --  ------------  --------------------  --------------------"

declare -a SELECTABLE
idx=1
for v in "${VERSIONS[@]}"; do
  url="https://download.mikrotik.com/routeros/$v/chr-$v.img.zip"
  av="UNKNOWN"
  if url_exists "$url"; then
    av="AVAILABLE"
    SELECTABLE[$idx]="$v"
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then
      # No fetch helper yet; exact check will be performed after apt setup.
      av="CHECK-ON-INSTALL"
      SELECTABLE[$idx]="$v"
    else
      av="NOT-AVAILABLE"
      SELECTABLE[$idx]=""
    fi
  fi

  if [[ "$av" == "NOT-AVAILABLE" ]]; then
    printf "  %-3s %-12s %-20s " "$idx)" "$v" "${CHANNEL[$v]:-OFFICIAL}"
    echo -e "${R}[NOT AVAILABLE]${N}"
  else
    printf "  %-3s %-12s %-20s " "$idx)" "$v" "${CHANNEL[$v]:-OFFICIAL}"
    if [[ "$NETMODE" == "DHCP" ]]; then
      echo -e "${G}[PING SAFE LIKELY]${N}"
    else
      echo -e "${Y}[IP MAY DROP / STATIC IP]${N}"
    fi
  fi
  idx=$((idx+1))
done

echo
echo "  0) Cancel"
echo

if [[ "$NETMODE" != "DHCP" ]]; then
  warn "This VPS uses STATIC or unconfirmed network configuration."
  warn "The warning beside each version is about keeping the VPS IP/Ping after first CHR boot."
fi

echo
warn "One-click mode: selecting a version starts the full install automatically."
warn "A successful install erases ALL DATA on $TARGET."
read -rp "Select version number: " CHOICE

[[ "$CHOICE" =~ ^[0-9]+$ ]] || die "Invalid selection."
[[ "$CHOICE" != "0" ]] || { echo "Cancelled."; exit 0; }
(( CHOICE > 0 && CHOICE < idx )) || die "Invalid selection."

VERSION="${SELECTABLE[$CHOICE]:-}"
[[ -n "$VERSION" ]] || die "That version has no verified official CHR x86_64 image."

URL="https://download.mikrotik.com/routeros/$VERSION/chr-$VERSION.img.zip"

echo
info "Selected RouterOS $VERSION (${CHANNEL[$VERSION]:-OFFICIAL})"
info "Starting automatic installation."

# ---------- Ubuntu update + missing dependencies ----------
have apt-get || die "Automatic mode supports Ubuntu/Debian with apt-get."
export DEBIAN_FRONTEND=noninteractive

info "Updating Ubuntu/Debian packages..."
apt-get update
apt-get -y upgrade

PKGS=()
have curl || PKGS+=(curl)
have unzip || PKGS+=(unzip)
if ((${#PKGS[@]})); then
  info "Installing only missing tools: ${PKGS[*]}"
  apt-get install -y "${PKGS[@]}"
fi

# Exact CHR verification before touching the disk.
info "Verifying official CHR x86_64 image URL..."
curl -fsIL --connect-timeout 10 --max-time 20 "$URL" >/dev/null \
  || die "Official CHR image is unavailable. Disk was NOT modified."

# ---------- Download to RAM ----------
RAMDIR="/dev/shm/chr-easy-installer"
mkdir -p "$RAMDIR"
ZIP="$RAMDIR/chr-${VERSION}.img.zip"
IMG="$RAMDIR/chr-${VERSION}.img"

FREE_KB="$(df -Pk /dev/shm | awk 'NR==2{print $4}')"
[[ "${FREE_KB:-0}" -gt 524288 ]] || die "/dev/shm needs at least 512 MiB free."

info "Downloading official MikroTik CHR $VERSION..."
rm -f "$ZIP" "$IMG"
curl -fL --retry 3 --connect-timeout 15 -o "$ZIP" "$URL"

info "Checking ZIP integrity..."
unzip -t "$ZIP" >/dev/null || die "Downloaded archive failed ZIP integrity check."

info "Extracting image to RAM..."
unzip -jo "$ZIP" "chr-${VERSION}.img" -d "$RAMDIR" >/dev/null
[[ -s "$IMG" ]] || die "CHR image extraction failed."

HASH="$(sha256sum "$IMG" | awk '{print $1}')"
ok "Official CHR image ready."
echo "  Version : $VERSION"
echo "  Channel : ${CHANNEL[$VERSION]:-OFFICIAL}"
echo "  SHA256  : $HASH"
echo "  Disk    : $TARGET"
echo

if [[ "$NETMODE" == "DHCP" ]]; then
  ok "Network assessment: DHCP detected; same MAC/IP is expected to be the safest path."
else
  warn "Network assessment: STATIC/UNKNOWN."
  warn "Installation will continue as requested, but ping preservation cannot be guaranteed."
  warn "Previous network: IP=${IPV4:-unknown} GW=${GW:-unknown} MAC=${MAC:-unknown}"
fi

have swapoff && swapoff -a 2>/dev/null || true
sync

info "Writing CHR x86_64 RouterOS $VERSION to $TARGET..."
dd if="$IMG" of="$TARGET" bs=4M conv=fsync status=progress

ok "MikroTik CHR installation completed."
echo
echo "Previous VPS network reference:"
echo "  IPv4    : ${IPV4:-unknown}"
echo "  Gateway : ${GW:-unknown}"
echo "  NIC/MAC : ${NIC:-unknown} / ${MAC:-unknown}"
echo
echo "MikroTik first login:"
echo "  Username: admin"
echo "  Password: empty on a fresh CHR image (set a strong password immediately)"
echo
info "Rebooting into MikroTik CHR..."
sleep 3

if [[ -w /proc/sysrq-trigger ]]; then
  echo b > /proc/sysrq-trigger
fi
reboot -f
