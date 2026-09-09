# نصب آسان MikroTik CHR

### نصب خودکار MikroTik CHR روی VPS با یک دستور

**توسعه داده شده توسط Ramin TR --- VIPserver-Team**

پروژه **MikroTik CHR Easy Installer** برای نصب خودکار Image رسمی
MikroTik Cloud Hosted Router (CHR) x86_64 روی VPSهای Ubuntu/Debian طراحی
شده است.

اولویت‌های پروژه: - نصب با یک دستور - حفظ IP و Ping سرور تا حد امکان -
ارائه روش No-Console VM در شرایطی که نصب مستقیم CHR ممکن است شبکه را
مختل کند

**English documentation:** [README.md](README.md)

## نصب سریع

``` bash
bash <(curl -fsSL https://raw.githubusercontent.com/VIPserver-Team/mikrotik-chr-installer-easy/main/Install.sh)
```

دستور را با دسترسی root اجرا کنید. Installer ابتدا VPS را Scan کرده، روش
مناسب‌تر را پیشنهاد می‌دهد و انتخاب نهایی روش نصب و نسخه RouterOS را به
کاربر می‌سپارد.

## روش‌های نصب

### Direct CHR

Ubuntu حذف شده و MikroTik CHR مستقیماً سیستم‌عامل VPS می‌شود.

مزایا: - بالاترین Performance - دسترسی مستقیم به CPU، RAM، Disk و NIC -
Overhead کمتر - مناسب‌تر برای VPN و Routing پرترافیک

**هشدار:** این روش دیسک سیستم را بازنویسی می‌کند. در شبکه‌های Static یا
خاص ممکن است پس از اولین Boot نیاز به بازیابی تنظیمات شبکه وجود داشته
باشد.

### No-Console VM

Ubuntu حفظ می‌شود و Public IP روی Ubuntu باقی می‌ماند. CHR با QEMU اجرا
می‌شود و در صورت امکان Docker به‌عنوان Wrapper استفاده می‌شود.

Engineهای ممکن: - `DOCKER_KVM` --- QEMU با KVM acceleration -
`DOCKER_TCG` --- شبیه‌سازی نرم‌افزاری در صورت نبود `/dev/kvm` -
`HOST_QEMU` --- روش fallback با QEMU روی Host

هدف این روش کاهش احتمال از دست رفتن SSH/Ping است.

## تشخیص خودکار VPS

Installer تا حد امکان این موارد را تشخیص می‌دهد: - Virtualization - CPU و
RAM - System Disk - Public IPv4 و Prefix - Default Gateway - NIC و MAC -
DHCP یا Static - Nested KVM - LVM و ساختارهای رایج VPS

نمونه:

``` text
Virtualization : VMware
CPU / RAM      : 1 vCPU / 1968 MB
System disk    : /dev/sda (20G)
Public IPv4    : 87.x.x.x/24
Gateway        : 87.x.x.254
NIC / MAC      : ens160 / xx:xx:xx:xx:xx:xx
Network mode   : STATIC
Nested KVM     : NO
```

Scan فقط پیشنهاد ارائه می‌دهد و انتخاب نهایی با کاربر است.

## منوی نصب

``` text
DIRECT CHR
1) RouterOS 7 Stable
2) RouterOS 7 Long-term
3) RouterOS 6 Stable
4) RouterOS 6 Long-term

NO-CONSOLE VM
5) RouterOS 7 Stable
6) RouterOS 7 Long-term
7) RouterOS 6 Stable
8) RouterOS 6 Long-term

0) Cancel
```

Imageهای رسمی CHR x86_64 از زیرساخت MikroTik دریافت می‌شوند.

## اولویت حفظ IP و Ping

در شبکه‌های ساده DHCP/MAC-bound، Direct CHR می‌تواند مناسب باشد. در
شبکه‌های Static یا نامشخص، No-Console VM می‌تواند Ubuntu و Public IP را
حفظ کند.

``` text
Network: STATIC
Direct install may lose IP -> No-Console VM recommended to preserve Ping.
```

هیچ Installer خودکاری نمی‌تواند روی تمام Providerها حفظ دسترسی را ۱۰۰٪
تضمین کند. `/32`، Routed Gateway، VLAN، MAC Filtering و شبکه‌های اختصاصی
Cloud ممکن است نیازمند تنظیمات ویژه باشند.

## مقایسه روش‌ها

  قابلیت                            Direct CHR      No-Console VM
  --------------------------------- --------------- --------------------
  حفظ Ubuntu                        خیر             بله
  باقی ماندن Public IP روی Ubuntu   خیر             بله
  Performance                       بهترین          وابسته به KVM/QEMU
  Overhead اضافه                    ندارد           دارد
  اجرا بدون Nested KVM              ---             بله، با TCG
  VPN/Routing پرترافیک              پیشنهاد می‌شود   KVM بهتر است
  ریسک برای شبکه فعلی Linux         بیشتر           کمتر

## Performance

برای WireGuard، IKEv2/IPsec، OpenVPN، SSTP، GRE، NAT، Queue و تعداد زیاد
کاربران VPN، Direct CHR یا CHR با KVM acceleration مناسب‌تر است. QEMU TCG
یک fallback سازگاری است و می‌تواند به‌طور محسوسی کندتر باشد.

## ورود اولیه

CHR تازه معمولاً با این مشخصات شروع می‌شود:

``` text
Username: admin
Password: empty
```

پس از ورود یک Password قوی تعیین کنید. در No-Console VM ممکن است
Installer Password مدیریتی تولید و در پایان نمایش دهد.

## محیط‌های هدف

پروژه عمدتاً برای Ubuntu/Debian x86_64 VPS، KVM/QEMU، VMware، VirtIO،
VMXNET3، LVM، `/dev/vda`، `/dev/sda` و ساختارهای رایج VPS طراحی شده است.

## امنیت

پس از نصب: - Password قوی تعیین کنید - Winbox و SSH را محدود کنید -
Firewall مناسب RouterOS تنظیم کنید - سرویس‌های غیرضروری را ببندید -
RouterOS را به‌روز نگه دارید - Backup منظم تهیه کنید

## هشدار مهم

**Direct CHR مخرب است.** دیسک سیستم بازنویسی شده و Ubuntu و اطلاعات
موجود روی آن حذف می‌شوند. قبل از استفاده از اطلاعات مهم Backup بگیرید.

## پروژه

**Repository:** `VIPserver-Team/mikrotik-chr-installer-easy`\
**Maintainer:** Ramin TR\
**Project:** VIPserver-Team

### سلب مسئولیت

این پروژه یک ابزار مستقل Community است و وابسته یا تأییدشده توسط
MikroTik نیست. نام‌های MikroTik، RouterOS و CHR متعلق به صاحبان مربوطه
هستند. مسئولیت استفاده از ابزار بر عهده کاربر است.
