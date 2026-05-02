# atomic-upgrade

[![CI](https://github.com/fkzys/atomic-upgrade/actions/workflows/ci.yml/badge.svg)](https://github.com/fkzys/atomic-upgrade/actions/workflows/ci.yml)
![License](https://img.shields.io/github/license/fkzys/atomic-upgrade)
[![Spec](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/fkzys/specs/refs/heads/main/version.json&maxAge=300)](https://github.com/fkzys/specs)

Atomic system upgrades for Arch Linux on Btrfs + UKI + optional Secure Boot.

NixOS/Silverblue-style generational updates on plain Arch: Btrfs snapshot → chroot → upgrade → build UKI → sign → reboot. Rollback is selecting a previous UKI entry in the boot menu.

## How it works

```
sudo atomic-upgrade
        ↓
  1. Btrfs snapshot of current root
  2. Mount snapshot, chroot into it
  3. Run command (default: pacman -Syu)
  4. Verify snapshot consistency (kernel, initramfs, modules)
  5. Update fstab (subvol=)
  6. Build UKI (ukify)
  7. Sign with sbctl (if SBCTL_SIGN=1)
  8. Garbage collect old generations
        ↓
  reboot → new generation active
```

Rollback: select a previous UKI entry in the boot menu.

Each generation is a snapshot + UKI pair. The UKI contains the kernel and initramfs from that snapshot, and its cmdline points to that specific subvolume. Rollback works because each boot menu entry maps to one complete system state.

## Comparison

> **Scope note:** Snapper and Timeshift are snapshot tools, not upgrade managers.
> The table compares common Arch ecosystem stacks that provide comparable
> end-to-end functionality. NixOS and Fedora Atomic are entire OS models.

| Feature | atomic-upgrade | Snapper + grub-btrfs | Timeshift + grub-btrfs | NixOS | Fedora Atomic |
|---------|---------------|---------------------|------------------------|-------|---------------|
| **Base distro** | Arch | Any (openSUSE native) | Any Btrfs | NixOS | Fedora |
| **Atomic upgrades** | ✓ (chroot) | ✗ (pre/post snapshots) | ✗ (pre/post snapshots) | ✓ | ✓ |
| **Rollback** | Boot menu (UKI) | Boot menu (GRUB) | Boot menu (GRUB) | Boot menu | Boot menu (GRUB) |
| **Secure Boot** | ✓ (sbctl, optional) | Via separate setup | Via separate setup | ✓ (lanzaboote) | ✓ |
| **UKI per generation** | ✓ | ✗ | ✗ | Optional | Optional |
| **Upgrade isolation** | Chroot snapshot | None (live) | None (live) | Nix build | OSTree |
| **Package manager** | pacman | Any (pacman, zypper…) | Any | nix | rpm-ostree |
| **AUR** | ✓ (native¹) | ✓ (transparent) | ✓ (transparent) | ✗ | ✗ |
| **LUKS handling** | Auto-detect + cmdline | N/A (not in scope) | N/A (not in scope) | Built-in | Built-in |
| **GC** | ✓ (auto + manual) | ✓ (timeline/number) | ✓ (by count) | ✓ | ✓ |
| **Codebase** | ~2000 LOC (bash+python) | Large (C++) | Large (Vala) | Entire OS | Entire OS |
| **Learning curve** | Low (plain Arch) | Low | Low | High (Nix lang) | Medium (OSTree) |

> ¹ AUR helpers work inside the snapshot — see [AUR helpers](#aur-helpers).

## Installation

### AUR

```bash
yay -S atomic-upgrade
```

### gitpkg
```bash
gitpkg install atomic-upgrade
```

### Manual

```bash
git clone https://github.com/fkzys/atomic-upgrade.git
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
atomic-gc list                                         # list all generations
sudo atomic-gc rm 20260217-143022                      # delete specific generation
sudo atomic-gc rm -y 20260217-143022 20260216-235122   # delete multiple without confirmation
sudo atomic-gc activate 20260217-143022                # mark as active (UEFI boots first)
sudo atomic-gc deactivate 20260217-143022              # remove active marker
sudo atomic-gc protect 20260217-143022                 # protect from garbage collection
sudo atomic-gc unprotect 20260217-143022               # remove protection
sudo atomic-rebuild-uki --list                         # show subvolumes and UKI status
sudo atomic-rebuild-uki 20250208-134725                # rebuild UKI for specific generation
```

### Shell completion

Tab completion is available for `atomic-gc`, `atomic-rebuild-uki`, and `atomic-upgrade` in both zsh and bash:

```bash
atomic-gc <TAB>              # → list  rm  activate  deactivate  protect  unprotect
atomic-gc rm <TAB>           # → generation IDs from ESP
atomic-gc activate <TAB>     # → generation IDs from ESP
atomic-rebuild-uki <TAB>     # → generation IDs from ESP
atomic-rebuild-uki -<TAB>    # → --help --list -h -l
atomic-upgrade -<TAB>        # → --dry-run --tag --no-gc --separate-home ...
```

Completions are installed automatically. For bash, the `bash-completion` package must
be installed and sourced in `~/.bashrc`:

```bash
# ~/.bashrc
[[ -r /usr/share/bash-completion/bash_completion ]] && . /usr/share/bash-completion/bash_completion
```

For zsh, completions are picked up automatically after restarting the shell
(`rm -f ~/.zcompdump* && exec zsh` if needed).

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
:: Verifying snapshot consistency...
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
| `CHROOT_COMMAND` | `/usr/bin/pacman -Syu` | Default command in snapshot chroot (overrides built-in `pacman -Syu`) |
| `SBCTL_SIGN` | `0` | Sign UKI files with sbctl for Secure Boot (`0`=off, `1`=on) |
| `UPGRADE_GUARD` | `1` | Upgrade guard: block direct `pacman -Syu` (`0`=off, `1`=on) |
| `HOME_COPY_FILES` | *(empty)* | Files to copy into isolated home subvolumes (see [Home isolation](#home-isolation)) |

> **Config syntax:** inline comments start at ` #` (space then hash).
> Values containing a literal ` #` sequence will be truncated. This does not
> affect typical paths or kernel parameters.

Default `KERNEL_PARAMS`: `rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off`

Root device is auto-detected (LUKS, LVM, LUKS+LVM, plain Btrfs). `MAPPER_NAME` is only used as a fallback if auto-detection fails.

### Secure Boot signing

UKI signing with `sbctl` is **disabled by default**. To enable:

1. Set up Secure Boot with sbctl (enroll keys, etc.)
2. Install `sbctl` if not already installed
3. Enable in config:

```bash
# /etc/atomic.conf
SBCTL_SIGN=1
```

When disabled, UKI files are built unsigned. They will boot on systems with Secure Boot disabled or in setup mode.

### Example: TPM2 auto-unlock

```bash
KERNEL_PARAMS="rd.luks.options=tpm2-device=auto rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off"
```

## Guard layers

The system has two layers preventing accidental direct upgrades, controlled by a single `UPGRADE_GUARD` config flag (enabled by default):

**Pacman hook** (`atomic-guard`) — blocks `pacman -Syu` at the transaction level. Allows:
- Package installs without `--sysupgrade` (`pacman -S`, `-R`, etc.)
- Upgrades via `atomic-upgrade` (env var + lock verification)
- Upgrades via AUR helpers (`yay`, `paru`, `pikaur`, `aura`)

**Pacman wrapper** (`/usr/local/bin/pacman`) — intercepts `pacman -Syu` and suggests `atomic-upgrade` instead. Detects AUR helpers as parent processes to avoid double prompts. Also warns about `-Sy` without `-u` (partial upgrade risk).

Both layers check `UPGRADE_GUARD` at runtime — the change takes effect immediately, no restart or file removal needed.

### Disabling the guard

```bash
# /etc/atomic.conf
UPGRADE_GUARD=0
```

This disables both the pacman hook and the wrapper in a single setting. Files remain on disk but are bypassed. To re-enable, set back to `1` (or remove the line — default is `1`).

### AUR helpers

AUR helpers (`yay`, `paru`, etc.) are allowed through the pacman hook guard
but by default run on the **live system**, not atomically. A warning is shown
when this happens.

**Recommended: run AUR helper inside the snapshot**

```bash
sudo atomic-upgrade -- sudo -u YOUR_USER yay -Syu
```

This creates a snapshot, chroots into it, and runs `yay -Syu` as your regular
user — updating both official and AUR packages atomically in a single generation.

Replace `YOUR_USER` with your username and `yay` with your AUR helper of choice.

**Installing a specific AUR package atomically:**

```bash
sudo atomic-upgrade -t my-pkg -- sudo -u YOUR_USER yay -S my-aur-package
```

**Multiple commands:**

```bash
sudo atomic-upgrade -- bash -c '/usr/bin/pacman -Syu && sudo -u YOUR_USER yay -S pkg1 pkg2'
```

> **Note:** If you run `yay -Syu` directly (outside `atomic-upgrade`), the
> upgrade applies to the live system and is **not atomic**. The next
> `atomic-upgrade` will snapshot whatever state the live system is in.

## Home isolation

> **This feature is for throwaway experiments, not permanent environments.**
> Permanent setups should use regular generations with the shared `/home` subvolume.

`--separate-home` creates an isolated `/home` subvolume for the generation — so
experiments with dotfiles, DE configs, or user-level packages don't pollute your
main home. If something goes wrong, delete the generation and the home subvolume
is orphaned; GC will warn you about it.

```bash
# Try KDE without touching your current home
sudo atomic-upgrade --separate-home -t kde -- pacman -S plasma-meta

# Experiment with dev tooling, bring specific dotfiles
sudo atomic-upgrade --separate-home -t dev --copy-files ".bashrc .ssh .gitconfig" -- pacman -S base-devel

# Dry run to preview
sudo atomic-upgrade --dry-run --separate-home -t test
```

**How it works:**

1. A new Btrfs subvolume `home-TAG` is created (or reused if it already exists)
2. User directories are created with correct ownership (users with UID ≥ 1000)
3. Files listed in `--copy-files` (or `HOME_COPY_FILES` from config) are copied from
   current `/home/<user>/` into the new home
4. The generation's fstab is updated so `/home` points to the new subvolume

**Constraints:**

- Requires `--tag` (the home subvolume is named `home-TAG`)
- `--copy-files` requires `--separate-home`
- File paths with spaces are not supported
- Absolute paths and `..` traversal are rejected for safety

**Cleanup:** GC never auto-deletes home subvolumes (they contain user data). When
all generations referencing a tag are gone, GC reports the orphan:

```
   Orphan home: home-kde (no generations with tag 'kde')
   To remove: btrfs subvolume delete /run/atomic/temp_root/home-kde
```

A default set of files to copy can be configured:

```bash
# /etc/atomic.conf
HOME_COPY_FILES=".bashrc .bash_profile .ssh .gnupg .gitconfig"
```

The `--copy-files` flag overrides `HOME_COPY_FILES` per invocation.

## Disk space checks

Before creating a snapshot, `atomic-upgrade` checks available disk space on both the Btrfs filesystem and the ESP:

- **Btrfs**: blocks only when free space is below the percentage threshold (default 10%) **and** below 2 GB absolute. On large disks where free percentage is low but tens of gigabytes are available, the operation proceeds with a warning.
- **ESP**: requires at least 250 MB free (one UKI is typically 200–230 MB).

If disk space cannot be determined (e.g. `btrfs` and `df` both fail), a warning is shown and the operation proceeds.

## Garbage collection

`atomic-gc` and the GC phase of `atomic-upgrade` keep the last N generations (default 3) plus the currently booted one. After deleting old generations, an orphan sweep removes:
- `root-*` subvolumes that have no matching UKI on the ESP
- UKI files on the ESP that have no matching subvolume

Orphan `home-*` subvolumes (where no generation with that tag exists) are **reported but never auto-deleted** — they may contain user data. Use `btrfs subvolume delete` to remove them manually.

If the ESP is not mounted during the orphan sweep phase, it is skipped with a warning — orphans will be cleaned up on the next run.

## Components

| File | Role |
|------|------|
| `atomic-upgrade` | Main upgrade script — snapshot, chroot, UKI, sign |
| `atomic-gc` | Generation management — garbage collection, list, manual delete |
| `atomic-guard` | Pacman hook — blocks direct `-Syu`, allows installs/removes |
| `atomic-rebuild-uki` | Rebuild UKI for existing snapshot |
| `common.sh` | Shared library (config, locking, btrfs, UKI build, GC, home skeleton) |
| `config.py` | Config file parser with proper quote handling via `shlex` |
| `fstab.py` | Safe fstab editing (atomic write + verification + rollback) |
| `rootdev.py` | Auto-detect root device type (LUKS/LVM/plain) and build kernel cmdline |
| `pacman-wrapper` | Optional `/usr/local/bin/pacman` wrapper |
| `atomic.conf` | Default config file — all options commented out, installed to `/etc/atomic.conf` |
| `00-block-direct-upgrade.hook` | Pacman pre-transaction hook — invokes `atomic-guard` to block direct `-Syu` |
| `completions/` | Zsh and bash tab completions for `atomic-gc`, `atomic-rebuild-uki`, and `atomic-upgrade` |
| `tests/` | Unit and integration tests — see [`tests/README.md`](tests/README.md) |

## Troubleshooting

### fstab uses `subvolid=` without `subvol=`

`atomic-upgrade` requires a `subvol=` option in the root fstab entry to track which generation is active. If your fstab uses only `subvolid=`, add `subvol=/your-current-subvol` to the mount options:

```bash
# Before (won't work):
UUID=xxx / btrfs rw,noatime,subvolid=256 0 0

# After (works):
UUID=xxx / btrfs rw,noatime,subvolid=256,subvol=/root-20260601-120000 0 0
```

> **Note:** When both `subvolid=` and `subvol=` are present, some kernels prioritize `subvolid=`. Consider removing `subvolid=` from fstab to avoid conflicts after generation switches.

### Low disk space warning on large disks

On disks larger than ~200 GB, the free percentage may drop below 10% while absolute free space is still well above 2 GB. In this case, `atomic-upgrade` shows a warning but proceeds normally. The operation is only blocked when both the percentage **and** absolute thresholds are crossed.

## Requirements

### Prerequisites

- Btrfs root filesystem on a subvolume (any name — snapshots are created as `root-<timestamp>`)
- A bootloader or UEFI firmware that discovers UKI files (Type #2 entries) — systemd-boot, rEFInd, direct UEFI boot, etc.
- Secure Boot with sbctl *(optional, enable with `SBCTL_SIGN=1`)*

The tool places `.efi` files into `ESP/EFI/Linux/` (signed or unsigned depending on `SBCTL_SIGN`). Any boot environment that picks up UKI files from that path will work.

> **Important:** `/home`, `/var/log`, `/var/cache`, and other stateful data
> should live on **separate Btrfs subvolumes**. Only the root subvolume is
> snapshotted and rolled back — anything on the same subvolume will be
> rolled back with it.
>
> ```
> subvolid=5 (top-level)
> ├── home         → /home
> ├── log          → /var/log
> ├── cache        → /var/cache
> ├── root-<timestamp> → / (current generation)
> ├── root-<timestamp> → previous generations
> └── ...
> ```

### Dependencies

Installed automatically via the AUR package:
- [`verify-lib`](https://github.com/fkzys/verify-lib) — validates shell libraries before sourcing (compiled C binary)
- `btrfs-progs`
- `systemd-ukify`
- `python` ≥ 3.10

Optional:
- `sbctl` — Secure Boot signing (enable with `SBCTL_SIGN=1`)
- `cryptsetup` — LUKS support
- `lvm2` — LVM support
- `bash-completion` — bash tab completions
