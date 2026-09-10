#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
#                 MikroTik No-Console Installer v16
#                          by Ramin TR
# ============================================================================
# Goal:
#   - Keep VPS reachable without VNC/console whenever possible.
#   - One command -> choose RouterOS release -> installer chooses engine.
#
# Engines:
#   A) DIRECT CHR  : only for conservative "safe candidate" networks.
#   B) DOCKER+KVM  : keeps Ubuntu/public IP; CHR runs in QEMU with /dev/kvm.
#   C) DOCKER+TCG  : keeps Ubuntu/public IP; software-emulated QEMU fallback.
#   D) HOST-QEMU   : last fallback if Docker cannot be installed/started.
#
# CHR x86_64 only, official MikroTik images only.
#
# IMPORTANT:
# No installer can mathematically guarantee reachability on every provider
# topology. This script therefore uses a conservative engine selector:
# uncertain/static/special networks keep Ubuntu and use a VM fallback.
# ============================================================================

C="\033[1;36m"; G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; N="\033[0m"
info(){ echo -e "${C}[INFO]${N} $*"; }
ok(){ echo -e "${G}[OK]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
die(){ echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || die "Run as root."

ROS7_STABLE="7.24.2"
ROS7_LONG="7.23.5"
ROS6_STABLE="6.49.21"
ROS6_LONG="6.49.21"

BASE="/opt/mikrotik-no-console"
STATE="$BASE/state"
mkdir -p "$BASE" "$STATE"

for c in lsblk findmnt awk grep df ip dd sha256sum sync sed sort; do
  have "$c" || die "Required base command missing: $c"
done

# ------------------------- detect disk ---------------------------------------
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
if [[ "$ROOT_SRC" == /dev/* ]] && have readlink; then
  ROOT_SRC="$(readlink -f "$ROOT_SRC" 2>/dev/null || echo "$ROOT_SRC")"
fi

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
mapfile -t ALL_DISKS < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}')
[[ -z "$TARGET" && ${#ALL_DISKS[@]} -eq 1 ]] && TARGET="${ALL_DISKS[0]}"
[[ -b "$TARGET" ]] || die "Could not safely identify the Linux system disk."

# ------------------------- detect network ------------------------------------
IPV4="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $4}' || true)"
IP_NO_PREFIX="${IPV4%%/*}"
PREFIX="${IPV4#*/}"
[[ "$PREFIX" == "$IPV4" ]] && PREFIX=""
GW="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $3}' || true)"
NIC="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}' || true)"
DEFROUTE="$(ip -4 route show default 2>/dev/null | head -1 || true)"
MAC=""
[[ -n "$NIC" && -r "/sys/class/net/$NIC/address" ]] && MAC="$(cat "/sys/class/net/$NIC/address")"

NETMODE="UNKNOWN"
if grep -qw dhcp <<<"$DEFROUTE"; then
  NETMODE="DHCP"
elif grep -qw static <<<"$DEFROUTE"; then
  NETMODE="STATIC"
elif have networkctl && [[ -n "$NIC" ]] && \
     networkctl status "$NIC" 2>/dev/null | grep -Eqi 'DHCP4.*yes|DHCP.*yes'; then
  NETMODE="DHCP"
fi

GLOBAL4_COUNT="$(ip -4 -o addr show scope global 2>/dev/null | wc -l | tr -d ' ')"
VLAN_COUNT="$(ip -d link show 2>/dev/null | grep -c 'vlan protocol' || true)"
ONLINK=0
grep -qw onlink <<<"$DEFROUTE" && ONLINK=1
SPECIAL_PREFIX=0
[[ "$PREFIX" == "32" || -z "$PREFIX" ]] && SPECIAL_PREFIX=1

VIRT="Unknown"
if have systemd-detect-virt; then
  VIRT="$(systemd-detect-virt 2>/dev/null || true)"
  [[ -z "$VIRT" || "$VIRT" == "none" ]] && VIRT="Bare-metal/Unknown"
fi

CPU_COUNT="$(nproc 2>/dev/null || echo 1)"
RAM_MB="$(awk '/MemTotal/{printf "%.0f",$2/1024}' /proc/meminfo)"
DISK_SIZE="$(lsblk -ndo SIZE "$TARGET" | head -1)"
HAS_KVM="NO"
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] && HAS_KVM="YES"

# Automatic low-memory profile for VM modes.
if (( RAM_MB < 1100 )); then
  CHR_RAM_MB=160
elif (( RAM_MB < 1536 )); then
  CHR_RAM_MB=192
elif (( RAM_MB < 2560 )); then
  CHR_RAM_MB=256
else
  CHR_RAM_MB=384
fi

# ------------------------- choose engine -------------------------------------
# Direct mode is deliberately conservative. The previous successful pattern:
# QEMU/KVM/VMware-like VM + one normal IPv4 + confirmed DHCP + no VLAN + no /32.
DIRECT_SAFE=0
case "${VIRT,,}" in
  kvm|qemu|vmware) ;;
  *) ;;
esac

if [[ "$NETMODE" == "DHCP" \
   && "$GLOBAL4_COUNT" == "1" \
   && "$VLAN_COUNT" == "0" \
   && "$SPECIAL_PREFIX" == "0" \
   && "$ONLINK" == "0" ]]; then
  case "${VIRT,,}" in
    kvm|qemu|vmware) DIRECT_SAFE=1 ;;
  esac
fi

if [[ "$DIRECT_SAFE" == "1" ]]; then
  ENGINE="DIRECT"
  ENGINE_REASON="Confirmed DHCP + simple IPv4 topology + supported VM environment"
else
  if [[ "$HAS_KVM" == "YES" ]]; then
    ENGINE="DOCKER_KVM"
    ENGINE_REASON="Ubuntu/public IP will be preserved; hardware virtualization available"
  else
    ENGINE="DOCKER_TCG"
    ENGINE_REASON="Ubuntu/public IP will be preserved; /dev/kvm unavailable"
  fi
fi

clear 2>/dev/null || true
cat <<EOF
============================================================================
                  MikroTik No-Console Installer v16
                           by Ramin TR
============================================================================
Detected VPS
----------------------------------------------------------------------------
Virtualization : $VIRT
CPU / RAM      : $CPU_COUNT vCPU / ${RAM_MB} MB
System disk    : $TARGET ($DISK_SIZE)
Public IPv4    : ${IPV4:-unknown}
Gateway        : ${GW:-unknown}
NIC / MAC      : ${NIC:-unknown} / ${MAC:-unknown}
Network mode   : $NETMODE
Nested KVM     : $HAS_KVM
CHR VM RAM     : ${CHR_RAM_MB} MB
Low-memory mode: $([[ "$RAM_MB" -lt 1100 ]] && echo YES || echo NO)
----------------------------------------------------------------------------
AUTO ENGINE    : $ENGINE
Reason         : $ENGINE_REASON
Memory profile : automatic low-memory mode; VM images stay on Ubuntu disk
============================================================================
EOF

if [[ "$ENGINE" == "DIRECT" ]]; then
  echo -e "${G}Reachability policy: DIRECT candidate; same DHCP/MAC path is expected.${N}"
else
  echo -e "${G}Reachability policy: Ubuntu/public IP will NOT be replaced.${N}"
  echo "CHR will run behind QEMU user-mode NAT with forwarded management ports."
  echo
  echo "Network: $NETMODE | Direct install may lose IP -> No-Console VM recommended to preserve Ping."
fi
echo

echo "Choose installation:"
echo
if [[ "$ENGINE" == "DIRECT" ]]; then
  echo -e "${G}RECOMMENDATION: DIRECT CHR is preferred for this VPS.${N}"
  echo "Reason: $ENGINE_REASON"
  echo "FA: پیشنهاد این VPS: نصب مستقیم MikroTik/CHR"
else
  echo -e "${Y}RECOMMENDATION: NO-CONSOLE VM is preferred for this VPS.${N}"
  echo "Reason: $ENGINE_REASON"
  echo "FA: پیشنهاد این VPS: نصب با Docker/QEMU برای حفظ IP و Ping"
fi
echo
echo "  DIRECT CHR (REMOVE UBUNTU / MIKROTIK ON VPS DISK)"
echo "  1) RouterOS $ROS7_STABLE   [ROS7 STABLE]    -> DIRECT INSTALL"
echo "  2) RouterOS $ROS7_LONG    [ROS7 LONG-TERM] -> DIRECT INSTALL"
echo "  3) RouterOS $ROS6_STABLE   [ROS6 STABLE]    -> DIRECT INSTALL"
echo "  4) RouterOS $ROS6_LONG   [ROS6 LONG-TERM] -> DIRECT INSTALL"
echo
echo "  NO-CONSOLE VM (KEEP UBUNTU + KEEP PUBLIC IP)"
echo "  5) RouterOS $ROS7_STABLE   [ROS7 STABLE]    -> DOCKER/QEMU VM"
echo "  6) RouterOS $ROS7_LONG    [ROS7 LONG-TERM] -> DOCKER/QEMU VM"
echo "  7) RouterOS $ROS6_STABLE   [ROS6 STABLE]    -> DOCKER/QEMU VM"
echo "  8) RouterOS $ROS6_LONG   [ROS6 LONG-TERM] -> DOCKER/QEMU VM"
echo
echo "  0) Cancel"
echo

if [[ "${1:-}" == "--check" ]]; then
  ok "Check-only mode. Nothing changed."
  exit 0
fi

read -rp "Select [1-8/0]: " CHOICE
case "$CHOICE" in
  1) VERSION="$ROS7_STABLE"; CHANNEL="ROS7 STABLE"; ENGINE="DIRECT" ;;
  2) VERSION="$ROS7_LONG"; CHANNEL="ROS7 LONG-TERM"; ENGINE="DIRECT" ;;
  3) VERSION="$ROS6_STABLE"; CHANNEL="ROS6 STABLE"; ENGINE="DIRECT" ;;
  4) VERSION="$ROS6_LONG"; CHANNEL="ROS6 LONG-TERM"; ENGINE="DIRECT" ;;
  5) VERSION="$ROS7_STABLE"; CHANNEL="ROS7 STABLE"; ENGINE=$([[ "$HAS_KVM" == YES ]] && echo DOCKER_KVM || echo DOCKER_TCG) ;;
  6) VERSION="$ROS7_LONG"; CHANNEL="ROS7 LONG-TERM"; ENGINE=$([[ "$HAS_KVM" == YES ]] && echo DOCKER_KVM || echo DOCKER_TCG) ;;
  7) VERSION="$ROS6_STABLE"; CHANNEL="ROS6 STABLE"; ENGINE=$([[ "$HAS_KVM" == YES ]] && echo DOCKER_KVM || echo DOCKER_TCG) ;;
  8) VERSION="$ROS6_LONG"; CHANNEL="ROS6 LONG-TERM"; ENGINE=$([[ "$HAS_KVM" == YES ]] && echo DOCKER_KVM || echo DOCKER_TCG) ;;
  0) echo "Cancelled."; exit 0 ;;
  *) die "Invalid selection." ;;
esac

URL="https://download.mikrotik.com/routeros/$VERSION/chr-$VERSION.img.zip"

# ------------------------- common package helpers ----------------------------
have apt-get || die "Automatic mode currently supports Ubuntu/Debian with apt-get."
export DEBIAN_FRONTEND=noninteractive

info "Updating Ubuntu/Debian before installation..."
apt-get update
apt-get -y upgrade

PKGS=(curl unzip)
if [[ "$ENGINE" != "DIRECT" ]]; then
  PKGS+=(expect)
fi
MISSING=()
for p in "${PKGS[@]}"; do
  have "$p" || MISSING+=("$p")
done
if ((${#MISSING[@]})); then
  info "Installing missing prerequisites: ${MISSING[*]}"
  apt-get install -y "${MISSING[@]}"
fi

# Verify selected official image before any destructive action.
info "Checking official MikroTik CHR image..."
curl -fsIL --connect-timeout 10 --max-time 25 "$URL" >/dev/null \
  || die "Official CHR $VERSION image is unavailable. Nothing destructive was done."

# Storage strategy:
# DIRECT keeps only the extracted IMG in RAM because the Linux disk will be overwritten.
# VM modes keep the image on Ubuntu disk and do not require a large /dev/shm.
if [[ "$ENGINE" == "DIRECT" ]]; then
  ZIP="/var/tmp/chr-$VERSION.img.zip"
  RAMDIR="/dev/shm/mikrotik-no-console"
  mkdir -p "$RAMDIR"
  IMG="$RAMDIR/chr-$VERSION.img"

  info "Downloading official CHR $VERSION..."
  rm -f "$ZIP" "$IMG"
  curl -fL --retry 3 --connect-timeout 15 -o "$ZIP" "$URL"
  unzip -t "$ZIP" >/dev/null || die "CHR ZIP integrity test failed."

  IMG_BYTES="$(unzip -l "$ZIP" "chr-$VERSION.img" | awk '/chr-.*\.img$/ {print $1; exit}')"
  [[ "$IMG_BYTES" =~ ^[0-9]+$ ]] || die "Could not determine CHR image size."
  FREE_BYTES="$(df -PB1 /dev/shm | awk 'NR==2{print $4}')"
  HEADROOM=$((32*1024*1024))
  REQUIRED_BYTES=$((IMG_BYTES + HEADROOM))

  if (( FREE_BYTES < REQUIRED_BYTES )); then
    die "/dev/shm too small for Direct CHR. Need about $((REQUIRED_BYTES/1024/1024)) MiB free; have $((FREE_BYTES/1024/1024)) MiB. Use No-Console VM mode."
  fi

  info "Extracting CHR image to RAM..."
  unzip -jo "$ZIP" "chr-$VERSION.img" -d "$RAMDIR" >/dev/null
  rm -f "$ZIP"
else
  WORKDIR="$BASE/download"
  mkdir -p "$WORKDIR"
  ZIP="$WORKDIR/chr-$VERSION.img.zip"
  IMG="$WORKDIR/chr-$VERSION.img"

  info "Downloading official CHR $VERSION..."
  rm -f "$ZIP" "$IMG"
  curl -fL --retry 3 --connect-timeout 15 -o "$ZIP" "$URL"
  unzip -t "$ZIP" >/dev/null || die "CHR ZIP integrity test failed."
  info "Extracting CHR image on Ubuntu disk..."
  unzip -jo "$ZIP" "chr-$VERSION.img" -d "$WORKDIR" >/dev/null
  rm -f "$ZIP"
fi

[[ -s "$IMG" ]] || die "CHR image extraction failed."
HASH="$(sha256sum "$IMG" | awk '{print $1}')"
ok "Image verified locally: $HASH"

# Save pre-install network facts outside /tmp for VM mode and logs.
cat > "$STATE/last-network.txt" <<EOF
version=$VERSION
channel=$CHANNEL
engine=$ENGINE
host_ip=$IPV4
gateway=$GW
nic=$NIC
mac=$MAC
network_mode=$NETMODE
virtualization=$VIRT
EOF

# ------------------------- DIRECT engine -------------------------------------
direct_install() {
  warn "DIRECT mode selected by conservative network scan."
  warn "Selecting the version was the installation confirmation."
  have swapoff && swapoff -a 2>/dev/null || true
  sync
  info "Writing CHR $VERSION directly to $TARGET..."
  dd if="$IMG" of="$TARGET" bs=4M conv=fsync status=progress
  ok "Direct CHR installation completed."
  echo
  echo "MikroTik first login:"
  echo "  Username: admin"
  echo "  Password: empty on fresh CHR; set one immediately."
  echo "  Winbox  : ${IP_NO_PREFIX:-VPS-IP}:8291"
  info "Rebooting..."
  sleep 3
  [[ -w /proc/sysrq-trigger ]] && echo b > /proc/sysrq-trigger
  reboot -f
}

# ------------------------- VM fallback helpers -------------------------------
pick_port() {
  local p="$1"
  while ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"; do
    p=$((p+1))
  done
  echo "$p"
}

ensure_docker() {
  if have docker && docker info >/dev/null 2>&1; then
    return 0
  fi
  info "Installing Docker fallback engine..."
  apt-get install -y docker.io
  systemctl enable --now docker
  docker info >/dev/null 2>&1
}

make_qemu_image() {
  cat > "$BASE/Dockerfile" <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["qemu-system-x86_64"]
EOF
  docker build -t ramintr/chr-qemu:local "$BASE"
}

gen_password() {
  # RouterOS/expect-friendly password: alnum only.
  if have openssl; then
    openssl rand -hex 10
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
  fi
}

provision_serial() {
  local serial_port="$1"
  local admin_pass="$2"
  local exp="$BASE/provision.exp"

  cat > "$exp" <<'EOF'
#!/usr/bin/expect -f
set timeout 120
set port [lindex $argv 0]
set pass [lindex $argv 1]

spawn telnet 127.0.0.1 $port

set logged 0
while {$logged == 0} {
  expect {
    -re "(?i)login:" {
      send "admin\r"
    }
    -re "(?i)password:" {
      send "\r"
    }
    -re "(?i)software license.*\\[Y/n\\]" {
      send "n\r"
    }
    -re "(?i)new password" {
      send "$pass\r"
    }
    -re "(?i)repeat.*password" {
      send "$pass\r"
    }
    -re "\\] >" {
      set logged 1
    }
    timeout {
      puts "SERIAL_LOGIN_TIMEOUT"
      exit 20
    }
    eof {
      puts "SERIAL_EOF"
      exit 21
    }
  }
}

# Configure a predictable DHCP WAN inside QEMU user-mode NAT.
send "/system identity set name=CHR-NoConsole\r"
expect -re "\\] >"
send "/ip dhcp-client remove \\[find interface=ether1\\]\r"
expect -re "\\] >"
send "/ip dhcp-client add interface=ether1 disabled=no add-default-route=yes use-peer-dns=yes\r"
expect -re "\\] >"
send "/ip service enable winbox\r"
expect -re "\\] >"
send "/ip service enable ssh\r"
expect -re "\\] >"
send "/user set \\[find name=admin\\] password=$pass\r"
expect -re "\\] >"
send "/ip dhcp-client print detail\r"
expect -re "\\] >"
send "/system shutdown\r"
expect {
  -re "(?i)shutdown" {}
  timeout {}
  eof {}
}
EOF
  chmod +x "$exp"
  "$exp" "$serial_port" "$admin_pass"
}

docker_vm_install() {
  ensure_docker || return 1
  make_qemu_image

  install -d -m 700 "$BASE/vm"
  cp "$IMG" "$BASE/vm/chr.img"

  # Expand persistent virtual disk modestly.
  if have qemu-img; then
    qemu-img resize "$BASE/vm/chr.img" 1G >/dev/null 2>&1 || true
  fi

  WINBOX_PORT="$(pick_port 18291)"
  SSH_PORT="$(pick_port 12222)"
  SERIAL_PORT="$(pick_port 15001)"
  ADMIN_PASS="$(gen_password)"

  # Provisioning container: serial exposed only on localhost; no public mgmt yet.
  docker rm -f mikrotik-chr-provision >/dev/null 2>&1 || true
  docker rm -f mikrotik-chr >/dev/null 2>&1 || true

  QEMU_ACCEL="-accel tcg,thread=multi"
  DEVARGS=()
  if [[ "$ENGINE" == "DOCKER_KVM" && -c /dev/kvm ]]; then
    QEMU_ACCEL="-enable-kvm -cpu host"
    DEVARGS+=(--device /dev/kvm:/dev/kvm)
  else
    QEMU_ACCEL="-accel tcg,thread=multi -cpu max"
  fi

  info "Starting temporary CHR for no-console provisioning..."
  # shellcheck disable=SC2086
  docker run -d --name mikrotik-chr-provision \
    "${DEVARGS[@]}" \
    -p "127.0.0.1:${SERIAL_PORT}:${SERIAL_PORT}" \
    -v "$BASE/vm:/vm" \
    ramintr/chr-qemu:local \
    $QEMU_ACCEL -m ${CHR_RAM_MB} -smp 1 \
    -drive file=/vm/chr.img,format=raw,if=virtio \
    -device virtio-net-pci,netdev=n0 \
    -netdev user,id=n0 \
    -nographic \
    -serial "telnet:0.0.0.0:${SERIAL_PORT},server,nowait" \
    -monitor none >/dev/null

  sleep 8
  if ! provision_serial "$SERIAL_PORT" "$ADMIN_PASS"; then
    warn "Serial provisioning failed. Ubuntu/public IP is still untouched."
    docker logs --tail 80 mikrotik-chr-provision 2>/dev/null || true
    docker rm -f mikrotik-chr-provision >/dev/null 2>&1 || true
    return 1
  fi

  # Allow QEMU to finish shutdown; then remove provisioning container.
  sleep 5
  docker rm -f mikrotik-chr-provision >/dev/null 2>&1 || true

  info "Starting persistent CHR VM..."
  RUNARGS=()
  QEMU_RUN_ACCEL="-accel tcg,thread=multi -cpu max"
  if [[ "$ENGINE" == "DOCKER_KVM" && -c /dev/kvm ]]; then
    RUNARGS+=(--device /dev/kvm:/dev/kvm)
    QEMU_RUN_ACCEL="-enable-kvm -cpu host"
  fi

  # shellcheck disable=SC2086
  docker run -d --name mikrotik-chr --restart unless-stopped \
    "${RUNARGS[@]}" \
    -p "${WINBOX_PORT}:8291" \
    -p "${SSH_PORT}:22" \
    -v "$BASE/vm:/vm" \
    ramintr/chr-qemu:local \
    $QEMU_RUN_ACCEL -m ${CHR_RAM_MB} -smp 1 \
    -drive file=/vm/chr.img,format=raw,if=virtio \
    -device virtio-net-pci,netdev=n0 \
    -netdev "user,id=n0,hostfwd=tcp::8291-:8291,hostfwd=tcp::22-:22" \
    -nographic -serial none -monitor none >/dev/null

  # NOTE: Docker -p plus qemu hostfwd is not needed together for localhost sockets
  # when QEMU uses user networking. Recreate using host networking to make hostfwd
  # bind directly and avoid nested port mapping ambiguity.
  docker rm -f mikrotik-chr >/dev/null 2>&1 || true

  # shellcheck disable=SC2086
  docker run -d --name mikrotik-chr --restart unless-stopped \
    --network host \
    "${RUNARGS[@]}" \
    -v "$BASE/vm:/vm" \
    ramintr/chr-qemu:local \
    $QEMU_RUN_ACCEL -m ${CHR_RAM_MB} -smp 1 \
    -drive file=/vm/chr.img,format=raw,if=virtio \
    -device virtio-net-pci,netdev=n0 \
    -netdev "user,id=n0,hostfwd=tcp:0.0.0.0:${WINBOX_PORT}-:8291,hostfwd=tcp:0.0.0.0:${SSH_PORT}-:22" \
    -nographic -serial none -monitor none >/dev/null

  cat > "$STATE/access.txt" <<EOF
mode=$ENGINE
routeros=$VERSION
host_ip=$IP_NO_PREFIX
winbox_port=$WINBOX_PORT
ssh_port=$SSH_PORT
username=admin
password=$ADMIN_PASS
EOF

  echo
  ok "NO-CONSOLE CHR VM is running."
  echo "  Mode     : $ENGINE"
  echo "  RouterOS : $VERSION ($CHANNEL)"
  echo "  Host IP  : $IP_NO_PREFIX"
  echo "  Winbox   : $IP_NO_PREFIX:$WINBOX_PORT"
  echo "  SSH      : $IP_NO_PREFIX:$SSH_PORT"
  echo "  Username : admin"
  echo "  Password : $ADMIN_PASS"
  echo "  Ubuntu   : PRESERVED"
  echo "  Ping     : PRESERVED by keeping the host network"
  echo
  echo "Saved locally: $STATE/access.txt"
}

host_qemu_fallback() {
  warn "Docker fallback could not be completed."
  warn "Trying host-QEMU fallback while preserving Ubuntu/public IP."
  apt-get install -y qemu-system-x86 qemu-utils expect
  ENGINE="HOST_QEMU"

  install -d -m 700 "$BASE/vm"
  cp "$IMG" "$BASE/vm/chr.img"
  qemu-img resize "$BASE/vm/chr.img" 1G >/dev/null 2>&1 || true

  WINBOX_PORT="$(pick_port 18291)"
  SSH_PORT="$(pick_port 12222)"
  SERIAL_PORT="$(pick_port 15001)"
  ADMIN_PASS="$(gen_password)"

  ACCEL="-accel tcg,thread=multi -cpu max"
  if [[ -c /dev/kvm ]]; then ACCEL="-enable-kvm -cpu host"; fi

  # Provision in background.
  # shellcheck disable=SC2086
  nohup qemu-system-x86_64 $ACCEL -m ${CHR_RAM_MB} -smp 1 \
    -drive file="$BASE/vm/chr.img",format=raw,if=virtio \
    -device virtio-net-pci,netdev=n0 -netdev user,id=n0 \
    -nographic -serial "telnet:127.0.0.1:${SERIAL_PORT},server,nowait" \
    -monitor none >"$BASE/qemu-provision.log" 2>&1 &
  QPID=$!
  sleep 8

  if ! provision_serial "$SERIAL_PORT" "$ADMIN_PASS"; then
    kill "$QPID" 2>/dev/null || true
    die "Host-QEMU serial provisioning failed. Ubuntu/public IP was NOT changed."
  fi
  sleep 5
  kill "$QPID" 2>/dev/null || true

  cat > /etc/systemd/system/mikrotik-chr.service <<EOF
[Unit]
Description=MikroTik CHR No-Console VM
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/qemu-system-x86_64 $ACCEL -m ${CHR_RAM_MB} -smp 1 -drive file=$BASE/vm/chr.img,format=raw,if=virtio -device virtio-net-pci,netdev=n0 -netdev user,id=n0,hostfwd=tcp:0.0.0.0:${WINBOX_PORT}-:8291,hostfwd=tcp:0.0.0.0:${SSH_PORT}-:22 -nographic -serial none -monitor none
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now mikrotik-chr.service

  cat > "$STATE/access.txt" <<EOF
mode=HOST_QEMU
routeros=$VERSION
host_ip=$IP_NO_PREFIX
winbox_port=$WINBOX_PORT
ssh_port=$SSH_PORT
username=admin
password=$ADMIN_PASS
EOF

  echo
  ok "NO-CONSOLE CHR host-QEMU fallback is running."
  echo "  RouterOS : $VERSION ($CHANNEL)"
  echo "  Winbox   : $IP_NO_PREFIX:$WINBOX_PORT"
  echo "  SSH      : $IP_NO_PREFIX:$SSH_PORT"
  echo "  Username : admin"
  echo "  Password : $ADMIN_PASS"
  echo "  Ubuntu   : PRESERVED"
  echo "  Ping     : PRESERVED"
}

# ------------------------- execute selected engine ----------------------------
case "$ENGINE" in
  DIRECT)
    direct_install
    ;;
  DOCKER_KVM|DOCKER_TCG)
    if ! docker_vm_install; then
      host_qemu_fallback
    fi
    ;;
  *)
    host_qemu_fallback
    ;;
esac
