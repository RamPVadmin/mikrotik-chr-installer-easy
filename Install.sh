#!/usr/bin/env bash
set -Eeuo pipefail
C="\033[1;36m"; G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; N="\033[0m"
die(){ echo -e "${R}[خطا]${N} $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "با root اجرا کنید: sudo bash $0"
need(){ command -v "$1" >/dev/null 2>&1; }
for x in lsblk findmnt awk grep df ip dd sha256sum sync; do need "$x" || die "$x نصب نیست"; done

rootdev="$(findmnt -n -o SOURCE /)"
pk="$(lsblk -no PKNAME "$rootdev" 2>/dev/null|head -1)"
disk="${pk:+/dev/$pk}"
[[ -b "$disk" ]] || die "دیسک سیستم خودکار پیدا نشد."
ip4="$(ip -4 -o addr show scope global | awk 'NR==1{print $4}')"
gw="$(ip -4 route show default | awk 'NR==1{print $3}')"
nic="$(ip -4 route show default | awk 'NR==1{print $5}')"
mac="$(cat /sys/class/net/${nic}/address 2>/dev/null || true)"
size="$(lsblk -ndo SIZE "$disk")"

banner(){
clear
echo -e "${C}====================================================${N}"
echo -e "${C}       MikroTik CHR One-Command Installer FA${N}"
echo -e "${C}====================================================${N}"
echo " Linux IP : ${ip4:-نامشخص}"
echo " Gateway  : ${gw:-نامشخص}"
echo " NIC      : ${nic:-نامشخص}   MAC: ${mac:-نامشخص}"
echo " Disk     : $disk ($size)"
echo
}
check(){
banner
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$disk"
echo; ip -br addr; echo; ip route
if need lspci; then echo; lspci -nn | grep -Ei 'ethernet|network|virtio|storage|sata|scsi' || true; fi
echo
read -rp "Enter برای برگشت..." _
}
install(){
local ver="$1"
banner
echo -e "${Y}نسخه انتخابی: RouterOS CHR $ver${N}"
echo
echo "نکته شبکه:"
echo "  • نصب Clean است؛ کانفیگ Linux به RouterOS کپی نمی‌شود."
echo "  • اگر VPS از DHCP/MAC binding استفاده کند، معمولاً همان IP برمی‌گردد."
echo "  • اگر Provider فقط Static IP بدهد، بعد از بوت باید IP/Gateway را از Console تنظیم کنید."
echo
echo -e "${R}هشدار: کل $disk پاک می‌شود.${N}"
read -rp "برای ادامه INSTALL را تایپ کنید: " ans
[[ "$ans" == "INSTALL" ]] || { echo "لغو شد."; sleep 1; return; }

if ! need curl; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip; fi
if ! need unzip; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y unzip; fi

local ram=/dev/shm/chr-install
mkdir -p "$ram"
local zip="$ram/chr-$ver.img.zip" img="$ram/chr-$ver.img"
local url="https://download.mikrotik.com/routeros/$ver/chr-$ver.img.zip"
[[ "$(df -Pk /dev/shm|awk 'NR==2{print $4}')" -gt 524288 ]] || die "/dev/shm حداقل 512MB فضای آزاد لازم دارد."

echo "دانلود رسمی MikroTik..."
rm -f "$zip" "$img"
curl -fL --retry 3 --connect-timeout 15 "$url" -o "$zip"
unzip -t "$zip" >/dev/null || die "ZIP خراب است."
unzip -jo "$zip" "chr-$ver.img" -d "$ram" >/dev/null
[[ -s "$img" ]] || die "IMG پیدا نشد."
echo "SHA256: $(sha256sum "$img"|awk '{print $1}')"
echo
echo "IP فعلی را برای یادداشت نگه دارید:"
echo "IP=$ip4  GW=$gw  NIC=$nic  MAC=$mac"
echo
read -rp "تایید نهایی؛ ERASE را تایپ کنید: " ans2
[[ "$ans2" == "ERASE" ]] || { echo "لغو شد."; sleep 1; return; }

swapoff -a 2>/dev/null || true
sync
echo "نوشتن CHR روی $disk ..."
dd if="$img" of="$disk" bs=4M conv=fsync status=progress
echo
echo -e "${G}نصب کامل شد. سیستم اکنون Reboot می‌شود.${N}"
echo "ورود اولیه CHR: user=admin ، password خالی؛ بلافاصله Password قوی تعیین کنید."
sleep 3
if [[ -w /proc/sysrq-trigger ]]; then echo b > /proc/sysrq-trigger; fi
reboot -f
}

while true; do
banner
echo "1) نصب RouterOS 7.24.2 Stable"
echo "2) نصب RouterOS 7.23.5 Long-term"
echo "3) نصب RouterOS 6.49.21 Long-term"
echo "4) وارد کردن نسخه دلخواه CHR"
echo "5) فقط بررسی Server / Disk / Network"
echo "0) خروج"
echo
read -rp "انتخاب: " ch
case "$ch" in
  1) install "7.24.2";;
  2) install "7.23.5";;
  3) install "6.49.21";;
  4) read -rp "نسخه، مثال 7.24.1 یا 6.49.21: " v
     [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "نسخه نامعتبر"; sleep 1; continue; }
     install "$v";;
  5) check;;
  0) exit 0;;
  *) echo "انتخاب نامعتبر"; sleep 1;;
esac
done
