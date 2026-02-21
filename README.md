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
sudo atomic-upgrade -- pacman -S nvidia-dkms           # install specific package
sudo atomic-upgrade -t nvidia -- pacman -S nvidia-dkms # custom command with tag
sudo atomic-gc                                         # clean old generations (keep last 3 + current)
sudo atomic-gc --dry-run 2                             # preview: keep last 2
sudo atomic-gc list                                    # list all generations
sudo atomic-gc rm 20260217-143022                      # delete specific generation
sudo atomic-rebuild-uki --list                         # show subvolumes and UKI status
sudo atomic-rebuild-uki 20250208-134725                # rebuild UKI for specific generation
```

### Example run

```
:: Current: /root-20260220-141710 → New: /root-20260221-010551
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
:: Running garbage collection...
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
| `BTRFS_MOUNT` | `/mnt/temp_root` | Btrfs top-level mount point |
| `NEW_ROOT` | `/mnt/newroot` | New snapshot mount point |
| `ESP` | `/efi` | EFI System Partition |
| `KEEP_GENERATIONS` | `3` | Generations to keep (excluding current) |
| `MAPPER_NAME` | `root_crypt` | dm-crypt mapper name (fallback if auto-detection fails) |
| `KERNEL_PKG` | `linux` | Kernel package (linux/linux-lts/linux-zen) |
| `KERNEL_PARAMS` | *(security defaults)* | Kernel command line parameters |

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
- Upgrades via AUR helpers (`yay`, `paru`, etc.)

### Pacman wrapper

A wrapper at `/usr/local/bin/pacman` intercepts `pacman -Syu` and suggests
`atomic-upgrade` instead. It detects AUR helpers to avoid double prompts.

To disable: `sudo rm /usr/local/bin/pacman`

## Garbage collection

`atomic-gc` and the GC phase of `atomic-upgrade` keep the last N generations (default 3) plus the currently booted one. After deleting old generations, an orphan sweep removes any `root-*` subvolumes that have no matching UKI on the ESP.

## Components

| File | Role |
|------|------|
| `atomic-upgrade` | Main upgrade script — snapshot, chroot, UKI, sign |
| `atomic-gc` | Generation management — garbage collection, list, manual delete |
| `atomic-guard` | Pacman hook — blocks direct `-Syu`, allows installs/removes |
| `atomic-rebuild-uki` | Rebuild UKI for existing snapshot |
| `common.sh` | Shared library (config, locking, btrfs, UKI build, GC) |
| `fstab.py` | Safe fstab editing (atomic write + verification + rollback) |
| `rootdev.py` | Auto-detect root device type (LUKS/LVM/plain) |

## Requirements

### Prerequisites

- Btrfs root filesystem
- systemd-boot
- Secure Boot set up with sbctl (keys enrolled)
- Root on a Btrfs subvolume (e.g. `@` or `root`)

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
