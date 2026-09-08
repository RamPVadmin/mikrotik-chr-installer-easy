#!/usr/bin/env bash
set -Eeuo pipefail
C="\033[1;36m"; G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; N="\033[0m"
die(){ echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }
warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
info(){ echo -e "${C}[INFO]${N} $*"; }
ok(){ echo -e "${G}[OK]${N} $*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
[[ $EUID -eq 0 ]] || die "Run as root."

refresh(){
 ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
 IPV4="$(ip -4 -o addr show scope global 2>/dev/null|awk 'NR==1{print $4}')"
 GW="$(ip -4 route show default 2>/dev/null|awk 'NR==1{print $3}')"
 NIC="$(ip -4 route show default 2>/dev/null|awk 'NR==1{print $5}')"
 MAC=""; [[ -n "$NIC" && -r /sys/class/net/$NIC/address ]] && MAC="$(cat /sys/class/net/$NIC/address)"
 ROOT_DISK=""
 local s="$ROOT_SRC" p="" i=0
 [[ "$s" == /dev/* ]] && s="$(readlink -f "$s" 2>/dev/null || echo "$s")"
 while [[ "$s" == /dev/* && $i -lt 8 ]]; do
   [[ "$(lsblk -ndo TYPE "$s" 2>/dev/null|head -1)" == disk ]] && { ROOT_DISK="$s"; break; }
   p="$(lsblk -ndo PKNAME "$s" 2>/dev/null|head -1 || true)"
   [[ -z "$p" ]] && break
   s="/dev/$p"; i=$((i+1))
 done
 mapfile -t DS < <(lsblk -dnpo NAME,TYPE|awk '$2=="disk"{print $1}')
 [[ -z "$ROOT_DISK" && ${#DS[@]} -eq 1 ]] && ROOT_DISK="${DS[0]}"
}
banner(){
 refresh; clear 2>/dev/null||true
 echo "============================================================"
 echo "           MikroTik CHR Easy Installer v3"
 echo "============================================================"
 echo "IPv4    : ${IPV4:-unknown}"
 echo "Gateway : ${GW:-unknown}"
 echo "NIC/MAC : ${NIC:-unknown} / ${MAC:-unknown}"
 echo "Root FS : ${ROOT_SRC:-unknown}"
 echo "Disk    : ${ROOT_DISK:-not detected}"
 echo "============================================================"; echo
}
check(){
 banner
 echo "READ-ONLY CHECK: no install, no package changes, no disk writes, no reboot."
 echo; lsblk -o NAME,PKNAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
 echo; ip -br -4 addr || true; echo; ip -4 route || true
 if have lspci; then echo; lspci -nn|grep -Ei 'ethernet|network|virtio|storage|sata|scsi|nvme'||true; fi
 echo; ok "Nothing was changed."; read -rp "Press Enter..." _
}
choose_disk(){
 mapfile -t D < <(lsblk -dnpo NAME,SIZE,TYPE|awk '$3=="disk"{print $1" "$2}')
 ((${#D[@]})) || die "No whole disks found."
 echo "Whole disks:"
 for i in "${!D[@]}"; do echo "  $((i+1))) ${D[$i]}"; done
 read -rp "Disk number (0=cancel): " n
 [[ "$n" =~ ^[0-9]+$ ]] && ((n>0 && n<=${#D[@]})) || return 1
 TARGET="$(awk '{print $1}' <<<"${D[$((n-1))]}")"
}
tools(){
 local m=(); have curl||m+=(curl); have unzip||m+=(unzip)
 if ((${#m[@]})); then
   have apt-get||die "Missing ${m[*]}; apt-get unavailable."
   info "Installing required download tools only now..."
   apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y "${m[@]}"
 fi
}
install(){
 local v="$1"; banner
 echo "Selected CHR: $v"; echo
 warn "Installation DESTROYS the selected disk."
 choose_disk || { echo "Cancelled."; sleep 1; return; }
 echo; echo "Target: $TARGET"
 echo "Current network: ${IPV4:-unknown}, gateway ${GW:-unknown}, ${NIC:-unknown}, MAC ${MAC:-unknown}"
 echo
 echo "Network note: Linux IP settings are not blindly copied to RouterOS."
 echo "DHCP/MAC-bound VPS networks normally reacquire their address."
 echo "Static-only providers may require console configuration after first boot."
 echo
 read -rp "Type INSTALL to continue: " a
 [[ "$a" == INSTALL ]] || { echo "Cancelled."; return; }
 tools
 local r=/dev/shm/chr-installer z="$r/chr-$v.img.zip" img="$r/chr-$v.img"
 local url="https://download.mikrotik.com/routeros/$v/chr-$v.img.zip"
 mkdir -p "$r"
 [[ "$(df -Pk /dev/shm|awk 'NR==2{print $4}')" -gt 524288 ]] || die "/dev/shm needs 512MiB free."
 info "Downloading official image: $url"
 rm -f "$z" "$img"; curl -fL --retry 3 --connect-timeout 15 -o "$z" "$url"
 unzip -t "$z" >/dev/null || die "ZIP integrity check failed."
 unzip -jo "$z" "chr-$v.img" -d "$r" >/dev/null
 [[ -s "$img" ]] || die "IMG extraction failed."
 echo "SHA256: $(sha256sum "$img"|awk '{print $1}')"
 echo; warn "FINAL WARNING: ALL DATA ON $TARGET WILL BE LOST."
 read -rp "Type ERASE $TARGET exactly: " b
 [[ "$b" == "ERASE $TARGET" ]] || { echo "Cancelled."; return; }
 have swapoff && swapoff -a 2>/dev/null || true
 sync; info "Writing CHR..."
 dd if="$img" of="$TARGET" bs=4M conv=fsync status=progress
 ok "CHR written successfully. Rebooting now."
 sleep 3
 [[ -w /proc/sysrq-trigger ]] && echo b >/proc/sysrq-trigger
 reboot -f
}
while true; do
 banner
 echo "1) Install RouterOS 7.24.2"
 echo "2) Install RouterOS 7.23.5"
 echo "3) Install RouterOS 6.49.21"
 echo "4) Install custom CHR version"
 echo "5) READ-ONLY server/network/disk check"
 echo "0) Exit"; echo
 read -rp "Select: " c
 case "$c" in
 1) install 7.24.2;; 2) install 7.23.5;; 3) install 6.49.21;;
 4) read -rp "Version: " v; [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && install "$v" || { warn "Invalid version."; sleep 1; };;
 5) check;; 0) exit;; *) warn "Invalid selection."; sleep 1;;
 esac
done
