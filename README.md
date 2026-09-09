# MikroTik CHR Easy Installer

### One-Command MikroTik CHR Installer for Ubuntu/Debian VPS

**by Ramin TR --- VIPserver-Team**

MikroTik CHR Easy Installer automates deployment of official MikroTik
Cloud Hosted Router (CHR) x86_64 images on Ubuntu/Debian VPS servers.

Main goals: - One-command installation - Preserve VPS IP/Ping whenever
possible - Provide a No-Console VM mode when direct CHR installation may
disrupt networking

**Persian documentation:** [README.fa.md](README.fa.md)

## Quick Install

``` bash
bash <(curl -fsSL https://raw.githubusercontent.com/VIPserver-Team/mikrotik-chr-installer-easy/main/Install.sh)
```

Run as root. The installer scans the VPS, recommends a deployment
method, and lets the user choose the final method and RouterOS release.

## Installation Modes

### Direct CHR

Ubuntu is removed and CHR becomes the VPS operating system.

Advantages: - Best performance - Direct CPU/RAM/disk/NIC access - Lower
virtualization overhead - Preferred for high-throughput VPN and routing
workloads

**Warning:** Direct mode overwrites the system disk. Static or unusual
provider networking may require network recovery after first boot.

### No-Console VM

Ubuntu remains installed and keeps the public IP. CHR runs under QEMU,
preferably wrapped by Docker.

Possible engines: - `DOCKER_KVM` --- QEMU with KVM acceleration -
`DOCKER_TCG` --- QEMU software emulation when `/dev/kvm` is
unavailable - `HOST_QEMU` --- host-level QEMU fallback

This mode is designed to reduce the risk of losing SSH/Ping access.

## Automatic VPS Detection

The installer detects, where available: - Virtualization platform - CPU
and RAM - System disk - Public IPv4/prefix - Default gateway - NIC and
MAC - DHCP/Static network mode - Nested KVM - Common LVM/VPS disk
layouts

Example:

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

The scan is a recommendation; the user chooses the final mode.

## Menu

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

Official CHR x86_64 images are downloaded from MikroTik infrastructure.

## Network Reachability

Preserving network access is a primary design goal. Simple
DHCP/MAC-bound VPS networks may be suitable for Direct CHR. Static or
uncertain networks can use No-Console VM so Ubuntu retains the existing
public IP.

``` text
Network: STATIC
Direct install may lose IP -> No-Console VM recommended to preserve Ping.
```

No automated installer can guarantee reachability on every provider.
`/32` addressing, routed gateways, VLANs, MAC filtering and custom cloud
networking may require special handling.

## Direct vs No-Console VM

  Feature                                Direct CHR   No-Console VM
  -------------------------------------- ------------ ---------------------
  Ubuntu preserved                       No           Yes
  Public IP remains on Ubuntu            No           Yes
  Performance                            Best         Depends on KVM/QEMU
  Extra virtualization overhead          No           Yes
  Works without nested KVM               N/A          Yes, via TCG
  Heavy VPN/routing                      Preferred    Prefer KVM
  Lower risk to existing Linux network   No           Yes

## Performance

For WireGuard, IKEv2/IPsec, OpenVPN, SSTP, GRE, NAT, queues and large
VPN deployments, Direct CHR or KVM-accelerated CHR is preferred. QEMU
TCG is a compatibility fallback and can be substantially slower.

## First Login

Fresh CHR commonly starts with:

``` text
Username: admin
Password: empty
```

Set a strong password immediately. No-Console mode may generate and
display an administrator password automatically.

## Supported Environments

Primarily designed for Ubuntu/Debian x86_64 VPS environments using
KVM/QEMU, VMware, VirtIO, VMXNET3, LVM, `/dev/vda`, `/dev/sda`, and
common VPS disk layouts.

## Security

After installation: - Set a strong administrator password - Restrict
Winbox and SSH - Configure RouterOS firewall rules - Disable unnecessary
management services - Keep RouterOS updated - Maintain backups

## Important Warning

**Direct CHR is destructive.** It overwrites the selected system disk
and permanently removes Ubuntu and existing data. Back up important data
first.

## Project

**Repository:** `VIPserver-Team/mikrotik-chr-installer-easy`\
**Maintainer:** Ramin TR\
**Project:** VIPserver-Team

### Disclaimer

Independent community project; not affiliated with, endorsed by, or
maintained by MikroTik. MikroTik, RouterOS and CHR are trademarks of
their respective owners. Use at your own risk.
