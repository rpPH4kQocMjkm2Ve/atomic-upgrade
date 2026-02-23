# atomic-upgrade

Atomic system upgrades for Arch Linux on Btrfs + UKI + Secure Boot.

NixOS/Silverblue-style generational updates on plain Arch: Btrfs snapshot → chroot → upgrade → build UKI → sign → reboot. Rollback is selecting a previous entry in systemd-boot.

## How it works

```
sudo atomic-upgrade
        ↓
  1. Btrfs snapshot of current root
  2. Mount snapshot, arch-chroot into it
  3. Run command (default: pacman -Syu)
  4. Update fstab (subvol=)
  5. Build UKI (ukify)
  6. Sign with sbctl (Secure Boot)
  7. Garbage collect old generations
        ↓
  reboot → new generation active
```

Rollback: select a previous UKI entry in systemd-boot at boot time.

## Comparison

> **Scope note:** Snapper and Timeshift are snapshot tools, not upgrade managers.
> The table compares common Arch ecosystem stacks that provide comparable
> end-to-end functionality. NixOS and Fedora Atomic are entire OS models.

| Feature | atomic-upgrade | Snapper + grub-btrfs | Timeshift + grub-btrfs | NixOS | Fedora Atomic |
|---------|---------------|---------------------|------------------------|-------|---------------|
| **Base distro** | Arch | Any (openSUSE native) | Any Btrfs | NixOS | Fedora |
| **Atomic upgrades** | ✓ (chroot) | ✗ (pre/post snapshots) | ✗ (pre/post snapshots) | ✓ | ✓ |
| **Rollback** | Boot menu (systemd-boot) | Boot menu (GRUB) | Boot menu (GRUB) | Boot menu | Boot menu (GRUB) |
| **Secure Boot** | ✓ (sbctl) | Via separate setup | Via separate setup | ✓ (lanzaboote) | ✓ |
| **UKI per generation** | ✓ | ✗ | ✗ | Optional | Optional |
| **Upgrade isolation** | Chroot snapshot | None (live) | None (live) | Nix build | OSTree |
| **Package manager** | pacman | Any (pacman, zypper…) | Any | nix | rpm-ostree |
| **AUR** | ✓ (native) | ✓ (transparent) | ✓ (transparent) | ✗ | ✗ |
| **LUKS handling** | Auto-detect + cmdline | N/A (not in scope) | N/A (not in scope) | Built-in | Built-in |
| **GC** | ✓ (auto + manual) | ✓ (timeline/number) | ✓ (by count) | ✓ | ✓ |
| **Codebase** | ~1500 LOC (bash+python) | Large (C++) | Large (Vala) | Entire OS | Entire OS |
| **Learning curve** | Low (plain Arch) | Low | Low | High (Nix lang) | Medium (OSTree) |

## Installation

### AUR

```bash
yay -S atomic-upgrade
```

### Manual

```bash
git clone https://gitlab.com/fkzys/atomic-upgrade.git
cd atomic-upgrade
sudo make install
```

## Usage

```bash
sudo atomic-upgrade                                    # full system upgrade
sudo atomic-upgrade --dry-run                          # preview without changes
sudo atomic-upgrade -t pre-nvidia                      # upgrade with custom tag
sudo atomic-upgrade --no-gc                            # upgrade without garbage collection
sudo atomic-upgrade -- pacman -S nvidia                # install specific package
sudo atomic-upgrade -t nvidia -- pacman -S nvidia-dkms # custom command with tag
sudo atomic-upgrade --no-gc -t cleanup -- pacman -Rns firefox
sudo atomic-gc                                         # clean old generations (keep last 3 + current)
sudo atomic-gc --dry-run 2                             # preview: keep last 2
sudo atomic-gc list                                    # list all generations
sudo atomic-gc rm 20260217-143022                      # delete specific generation
sudo atomic-gc rm -y 20260217-143022 20260216-235122   # delete multiple without confirmation
sudo atomic-rebuild-uki --list                         # show subvolumes and UKI status
sudo atomic-rebuild-uki 20250208-134725                # rebuild UKI for specific generation
```

### Example run

```
:: Current: /root-20260220-141710 → New: /root-20260221-010551
:: Command: /usr/bin/pacman -Syu
:: Verifying current system...
:: Verifying current subvolume...
:: Checking disk space...
   Disk space: 76% free (~365GB)
   ESP space: 763MB free
:: Creating snapshot...
:: Mounting new root...
:: Running: /usr/bin/pacman -Syu
   [... pacman output ...]
:: Updating fstab...
:: Building UKI...
Wrote unsigned /efi/EFI/Linux/arch-20260221-010551.efi
:: Signing UKI for Secure Boot...
✓ Signed /efi/EFI/Linux/arch-20260221-010551.efi
:: Unmounting new root...
:: Verifying signature...
✓ /efi/EFI/Linux/arch-20260221-010551.efi is signed
:: Running garbage collection...
:: Garbage collecting (keeping last 3 + current)...
   Keeping: 20260221-010551
   Keeping: 20260220-141710 (current)
   Keeping: 20260216-235122
   Keeping: 20260212-202715
:: Garbage collection done
Generation 20260221-010551 ready. Reboot to activate.
```

## Configuration

Edit `/etc/atomic.conf`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BTRFS_MOUNT` | `/run/atomic/temp_root` | Btrfs top-level mount point |
| `NEW_ROOT` | `/run/atomic/newroot` | New snapshot mount point |
| `ESP` | `/efi` | EFI System Partition |
| `KEEP_GENERATIONS` | `3` | Generations to keep (excluding current) |
| `MAPPER_NAME` | `root_crypt` | dm-crypt mapper name (fallback if auto-detection fails) |
| `KERNEL_PKG` | `linux` | Kernel package (linux/linux-lts/linux-zen) |
| `KERNEL_PARAMS` | *(security defaults)* | Kernel command line parameters |

Default `KERNEL_PARAMS`: `rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off`

Root device is auto-detected (LUKS, LVM, LUKS+LVM, plain Btrfs). `MAPPER_NAME` is only used as a fallback if auto-detection fails.

### Example: TPM2 auto-unlock

```bash
KERNEL_PARAMS="rd.luks.options=tpm2-device=auto rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off"
```

## Guard layers

The system has two optional layers preventing accidental direct upgrades:

**Pacman hook** (`atomic-guard`) — blocks `pacman -Syu` at the hook level. Installed automatically. Allows:
- Package installs without `--sysupgrade` (`pacman -S`, `-R`, etc.)
- Upgrades via `atomic-upgrade` (env var + lock verification)
- Upgrades via AUR helpers (`yay`, `paru`, `pikaur`, `aura`)

### Pacman wrapper

A wrapper at `/usr/local/bin/pacman` intercepts `pacman -Syu` and suggests
`atomic-upgrade` instead. It detects AUR helpers to avoid double prompts.
Also warns about `-Sy` without `-u` (partial upgrade risk).

To disable: `sudo rm /usr/local/bin/pacman`

## Garbage collection

`atomic-gc` and the GC phase of `atomic-upgrade` keep the last N generations (default 3) plus the currently booted one. After deleting old generations, an orphan sweep removes:
- `root-*` subvolumes that have no matching UKI on the ESP
- UKI files on the ESP that have no matching subvolume

## Components

| File | Role |
|------|------|
| `atomic-upgrade` | Main upgrade script — snapshot, chroot, UKI, sign |
| `atomic-gc` | Generation management — garbage collection, list, manual delete |
| `atomic-guard` | Pacman hook — blocks direct `-Syu`, allows installs/removes |
| `atomic-rebuild-uki` | Rebuild UKI for existing snapshot |
| `common.sh` | Shared library (config, locking, btrfs, UKI build, GC) |
| `fstab.py` | Safe fstab editing (atomic write + verification + rollback) |
| `rootdev.py` | Auto-detect root device type (LUKS/LVM/plain) and build kernel cmdline |
| `pacman-wrapper` | Optional `/usr/local/bin/pacman` wrapper |

## Requirements

### Prerequisites

- Btrfs root filesystem
- systemd-boot
- Secure Boot set up with sbctl (keys enrolled)
- Root on a Btrfs subvolume (any name — snapshots are created as `root-<timestamp>`)

### Dependencies

Installed automatically via the AUR package:
- `btrfs-progs`
- `systemd-ukify`
- `sbctl`
- `python` ≥ 3.10
- `arch-install-scripts` (provides `arch-chroot`)

Optional:
- `cryptsetup` — LUKS support
- `lvm2` — LVM support
