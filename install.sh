#!/bin/sh
# Void Linux (musl) installer for a Lenovo V15 G4 IRU
# LUKS2 + Btrfs + runit + Limine + Sway/SwayFX + zsh, no display manager.
#
# HOW TO USE
#   1. Boot the Void live ISO (musl, base), log in as root / voidlinux.
#   2. Connect to the internet (guide section 2).
#   3. Edit the settings below, then run:  sh install.sh
#
# You will be asked for: a YES confirmation, the disk passphrase (twice),
# the root password and your user password. Everything else is automatic.
#
# WARNING: this ERASES everything on $DISK.

set -eu

# ---- settings: edit these ----------------------------------------------
DISK=/dev/nvme0n1
NEW_HOST=void
NEW_USER=sachie
TZ_NAME=Asia/Baku
COMPOSITOR=sway        # sway or swayfx
REPO=https://repo-default.voidlinux.org/current/musl
# -------------------------------------------------------------------------

case "$DISK" in
    *nvme*|*mmcblk*) PART="${DISK}p" ;;
    *) PART="$DISK" ;;
esac
EFI_PART="${PART}1"
LUKS_PART="${PART}2"

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---- sanity checks -------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run this as root"
[ -d /sys/firmware/efi ] || die "not booted in UEFI mode"
[ -b "$DISK" ] || die "$DISK does not exist (check lsblk)"
case "$COMPOSITOR" in sway|swayfx) ;; *) die "COMPOSITOR must be sway or swayfx" ;; esac
ping -c 1 -W 3 repo-default.voidlinux.org >/dev/null 2>&1 \
    || die "no internet: connect Wi-Fi first (guide section 2)"

echo "This will ERASE everything on $DISK:"
lsblk "$DISK"
printf '\nType YES to continue: '
read -r answer
[ "$answer" = YES ] || die "aborted"

# ---- live system prep ----------------------------------------------------
step "Updating xbps on the live system"
xbps-install -Syu xbps
command -v xgenfstab >/dev/null 2>&1 && command -v xchroot >/dev/null 2>&1 \
    || xbps-install -Sy xtools

# ---- disk ----------------------------------------------------------------
step "Partitioning $DISK (1G EFI + rest LUKS)"
wipefs -af "$DISK"
sfdisk "$DISK" <<EOF
label: gpt
,1G,U
,,L
EOF
udevadm settle 2>/dev/null || sleep 2

step "Encrypting $LUKS_PART: choose your disk passphrase"
cryptsetup luksFormat --type luks2 "$LUKS_PART"
cryptsetup open "$LUKS_PART" cryptroot

step "Formatting"
mkfs.vfat -F32 -n EFI "$EFI_PART"
mkfs.btrfs -f -L void /dev/mapper/cryptroot

step "Creating Btrfs subvolumes"
mount /dev/mapper/cryptroot /mnt
for s in @ @home @snapshots @log; do
    btrfs subvolume create "/mnt/$s"
done
umount /mnt

O=compress=zstd,noatime
mount -o "$O,subvol=@" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot /mnt/home /mnt/.snapshots /mnt/var/log
mount -o "$O,subvol=@home" /dev/mapper/cryptroot /mnt/home
mount -o "$O,subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount -o "$O,subvol=@log" /dev/mapper/cryptroot /mnt/var/log
mount "$EFI_PART" /mnt/boot

# ---- packages ------------------------------------------------------------
step "Installing packages (this takes a while)"
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
XBPS_ARCH=x86_64-musl xbps-install -Sy -r /mnt -R "$REPO" \
    base-system cryptsetup btrfs-progs limine efibootmgr \
    opendoas iwd openresolv vim \
    seatd zramen acpid chrony pipewire wireplumber \
    "$COMPOSITOR" swaylock swayidle swaybg foot fuzzel mako \
    grim slurp wl-clipboard brightnessctl \
    mesa-dri intel-media-driver \
    xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
    noto-fonts-ttf noto-fonts-emoji \
    zsh zsh-autosuggestions zsh-syntax-highlighting \
    flatpak wireguard-tools iptables-nft \
    fastfetch htop igt-gpu-tools

xgenfstab -U /mnt > /mnt/etc/fstab
cp /etc/resolv.conf /mnt/etc/resolv.conf

LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART")
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
[ -n "$LUKS_UUID" ] && [ -n "$ROOT_UUID" ] || die "could not read UUIDs"

# ---- everything inside the new system ------------------------------------
step "Writing the chroot setup script"
cat > /mnt/root/setup.sh <<'CHROOT'
#!/bin/sh
set -eu
step() { printf '\n==> %s\n' "$*"; }

step "Hostname, time zone"
echo "$NEW_HOST" > /etc/hostname
ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
printf 'TIMEZONE="%s"\nHARDWARECLOCK="UTC"\n' "$TZ_NAME" >> /etc/rc.conf

step "Users"
echo "Set the ROOT password:"
until passwd; do echo "Try again."; done
useradd -m -s /bin/zsh -G wheel,audio,video,input "$NEW_USER"
usermod -aG _seatd "$NEW_USER" || echo "WARNING: could not add $NEW_USER to _seatd"
echo "Set the password for $NEW_USER:"
until passwd "$NEW_USER"; do echo "Try again."; done

step "doas instead of sudo"
echo "permit persist :wheel" > /etc/doas.conf
mkdir -p /etc/xbps.d
echo "ignorepkg=sudo" > /etc/xbps.d/ignore.conf
xbps-remove -y sudo || true

step "initramfs settings and Intel microcode"
cat > /etc/dracut.conf.d/10-host.conf <<'EOF'
hostonly="yes"
early_microcode="yes"
EOF
xbps-install -Sy void-repo-nonfree
xbps-install -Sy intel-ucode

step "Network (iwd + openresolv)"
mkdir -p /etc/iwd
cat > /etc/iwd/main.conf <<'EOF'
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
EOF

step "Audio (PipeWire)"
mkdir -p /etc/pipewire/pipewire.conf.d
ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/

step "Enabling services"
for sv in dbus iwd seatd zramen acpid chronyd; do
    ln -sf "/etc/sv/$sv" /etc/runit/runsvdir/default/
done

step "Limine bootloader"
mkdir -p /boot/EFI/limine /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/BOOTX64.EFI
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
efibootmgr --create --disk "$DISK" --part 1 \
    --label "Limine" --loader '\EFI\limine\BOOTX64.EFI' \
    || echo "WARNING: efibootmgr failed; the fallback EFI/BOOT/BOOTX64.EFI will still boot"

mkdir -p /etc/kernel.d/post-install /etc/kernel.d/post-remove
cat > /etc/kernel.d/post-install/99-limine <<'HOOK'
#!/bin/sh
CMD="rd.luks.uuid=LUKS_UUID root=UUID=ROOT_UUID rootflags=subvol=@ loglevel=4"
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/BOOTX64.EFI
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
{
    echo "timeout: 3"
    for k in $(ls -r /boot/vmlinuz-*); do
        v=${k#/boot/vmlinuz-}
        echo "/Void $v"
        echo "    protocol: linux"
        echo "    path: boot():/vmlinuz-$v"
        echo "    module_path: boot():/initramfs-$v.img"
        echo "    cmdline: $CMD"
    done
} > /boot/limine.conf
HOOK
sed -i "s/LUKS_UUID/$LUKS_UUID/; s/ROOT_UUID/$ROOT_UUID/" /etc/kernel.d/post-install/99-limine
chmod +x /etc/kernel.d/post-install/99-limine
ln -sf ../post-install/99-limine /etc/kernel.d/post-remove/99-limine

step "Building initramfs and running kernel hooks"
xbps-reconfigure -fa
grep -q "$ROOT_UUID" /boot/limine.conf || { echo "ERROR: limine.conf looks wrong"; exit 1; }

step "Dotfiles for $NEW_USER"
H="/home/$NEW_USER"

cat > "$H/.zshrc" <<'EOF'
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt share_history hist_ignore_dups

autoload -Uz compinit && compinit
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
# syntax highlighting must stay the last line
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF

cat > "$H/.zprofile" <<'EOF'
export XDG_RUNTIME_DIR=/tmp/$(id -u)-runtime
mkdir -pm 0700 "$XDG_RUNTIME_DIR"
export XDG_CURRENT_DESKTOP=sway
[ "$(tty)" = /dev/tty1 ] && exec dbus-run-session sway
EOF

mkdir -p "$H/.config/sway"
cp /etc/sway/config "$H/.config/sway/config"
sed -i 's/^set \$menu .*/set $menu fuzzel/' "$H/.config/sway/config"
cat >> "$H/.config/sway/config" <<'EOF'

exec dbus-update-activation-environment --all
exec pipewire
exec mako
EOF
if [ "$COMPOSITOR" = swayfx ]; then
    cat >> "$H/.config/sway/config" <<'EOF'

# SwayFX effects
corner_radius 8
blur enable
blur_passes 2
shadows enable
EOF
fi

cat > "$H/post-install.sh" <<'EOF'
#!/bin/sh
# Run as your user after the first boot, once Wi-Fi is connected:
#   iwctl  ->  station wlan0 connect "SSID"
#   sh ~/post-install.sh
set -eu
flatpak remote-add --user --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub \
    io.gitlab.librewolf-community \
    net.mullvad.MullvadBrowser \
    org.prismlauncher.PrismLauncher \
    dev.vencord.Vesktop \
    com.vscodium.codium
echo
echo "Done. For Mullvad VPN, download WireGuard configs from your"
echo "Mullvad account and follow guide section 13."
EOF
chmod +x "$H/post-install.sh"

chown -R "$NEW_USER:$NEW_USER" "$H"
CHROOT

step "Running setup inside the new system"
xchroot /mnt env \
    DISK="$DISK" NEW_HOST="$NEW_HOST" NEW_USER="$NEW_USER" \
    TZ_NAME="$TZ_NAME" COMPOSITOR="$COMPOSITOR" \
    LUKS_UUID="$LUKS_UUID" ROOT_UUID="$ROOT_UUID" \
    /bin/sh /root/setup.sh

rm -f /mnt/root/setup.sh

step "Unmounting"
umount -R /mnt
cryptsetup close cryptroot

cat <<EOF

==> Install finished.
Remove the USB stick and run: reboot

After boot: unlock the disk, log in as $NEW_USER on tty1 (Sway starts),
connect Wi-Fi with iwctl, then run: sh ~/post-install.sh
EOF
