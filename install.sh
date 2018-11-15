# -----------------------------------
# Initial setup
# -----------------------------------

# Temporarily set keymap and font
loadkeys uk
setfont latarcyrheb-sun32

# Verify boot mode, i.e. check directory exists
ls /sys/firmware/efi/efivars

# Connect to the internet
wifi-menu

# Sync system clock with NTP servers
timedatectl set-ntp true

# Create ESP and Linux root partitions:
# 1. nvme0n1p1: 0xEF00: 550MB Primary FAT32 EFI System Partition (ESP)
# 2. nvme0n1p2: 0x8300 Linux root (to be encrypted)
#    https://wiki.archlinux.org/index.php/EFI_system_partition
cgdisk /dev/nvme0n1

# -----------------------------------
# Setup Linux root partition (nvme0n1p2)
# -----------------------------------

# Setup encryption
cryptsetup luksFormat /dev/nvme0n1p2  # Enter good passphrase
cryptsetup open /dev/nvme0n1p2 luks
mkfs.btrfs -L luks /dev/mapper/luks

# Create subvolumes
mount /dev/mapper/luks /mnt
btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots_root
btrfs subvolume create /mnt/@snapshots_home
umount /mnt

# Mount subvolumes
mount /dev/mapper/luks /mnt -o subvol=@root  # Top-level (subvolid=5)
mkdir /mnt/{home,.snapshots}
mount /dev/mapper/luks /mnt/home -o subvol=@home
mount /dev/mapper/luks /mnt/.snapshots -o subvol=/@snapshots_root
mount /dev/mapper/luks /mnt/home/.snapshots -o subvol=/@snapshots_home

# -----------------------------------
# Setup ESP (nvme0n1p1)
# -----------------------------------

mkfs.fat -F32 /dev/nvme0n1p1
mkdir /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot

# -----------------------------------
# Install base system
# -----------------------------------

# Move closer mirror to top
vim /etc/pacman.d/mirrorlist
# Uncomment Color option
vim /etc/pacman.conf
pacstrap /mnt base vim btrfs-progs zsh vim git sudo wpa_supplicant dialog iw intel-ucode

# Generate fstab
genfstab -L /mnt >> /mnt/etc/fstab
# Verify and adjust fstab: for all btrfs filesystems:
# - Change "relatime" to "noatime" to reduce wear on SSD
# - Add "discard" to enable continuous TRIM for SSD
# - Add "autodefrag" to enable online defragmentation
vim /mnt/etc/fstab

# -----------------------------------
# Configure system
# -----------------------------------

arch-chroot /mnt

# Configure timezone
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

# Generate locales
vim /etc/locale.gen  # en_GB.UTF-8 UTF-8
locale-gen
echo 'LANG=en_GB.UTF-8' > /etc/locale.conf

# Permanently set keymap and font
cat <<EOT >> /etc/vconsole.conf
KEYMAP=uk
FONT=latarcyrheb-sun32
EOT

# Set hostname (e.g. joe-thinkpad)
echo '<hostname>' > /etc/hostname
cat <<EOT >> /etc/hosts
127.0.0.1	localhost
::1		localhost
127.0.1.1	<hostname>.localdomain <hostname>
EOT

# Configure mkinitcpio with kernel modules needed for the initrd image
# + https://wiki.archlinux.org/index.php/mkinitcpio#Common_hooks
# HOOKS=(base systemd autodetect modconf block keyboard sd-vconsole sd-encrypt filesystems)
vim /etc/mkinitcpio.conf
# Regenerate initrd image
mkinitcpio -p linux

# Setup systemd-boot
bootctl --path=/boot install
# Create bootloader entry
# https://wiki.archlinux.org/index.php/Dm-crypt/System_configuration#Using_sd-encrypt_hook
cat <<EOT > /boot/loader/entries/arch.conf
title 		Arch Linux
linux		/vmlinuz-linux
initrd		/intel-ucode.img
initrd		/initramfs-linux.img
options		rw luks.name=luks rd.luks.options=discard root=/dev/mapper/luks rootflags=subvol=@root fan_control=1
EOT
# Set default bootloader entry
cat <<EOT > /boot/loader/loader.conf
#timeout	3
console-mode	2
default 	arch
EOT

# Set password for root
passwd

# Add user
useradd -m -g wheel -s /bin/zsh joenye
passwd joenye
vim /etc/sudoers # Uncomment %wheel ALL=(ALL) ALL

# Reboot
exit
reboot

# -----------------------------------
# Networking
# -----------------------------------

# Uses systemd-networkd
sudo systemctl enable systemd-networkd
sudo systemctl start systemd-networkd
sudo systemctl enable systemd-resolved
sudo systemctl start systemd-resolved
sudo cat <<EOT > /etc/systemd/network/20-wired.network
[Match]
Name=enp0s31f6

[Network]
DHCP=yes

[DHCP]
RouteMetric=10
EOT
sudo cat <<EOT > /etc/systemd/network/25-wireless.network
[Match]
Name=wlp4s0

[Network]
DHCP=yes

[DHCP]
RouteMetric=20
EOT
sudo cat <<EOT > /etc/wpa_supplicant/wpa_supplicant-wlp4s0.conf
ctrl_interface=DIR=/run/wpa_supplicant GROUP=wheel
update_config=1
EOT
sudo systemctl enable wpa_supplicant@wlp4s0
sudo systemctl start wpa_supplicant@wlp4s0

# Add new connection
sudo wpa_cli -i wlp4s0
scan
scan_results
add_network
set_network 0 ssid "<ssid>"
set_network 0 psk "<psk>"  (if no psk, must do set_network 0 key_mgmt NONE)
enable_network 0
save_config
exit
# Or add manually to /etc/wpa_supplicant/wpa_supplicant-wlp4s0.conf
# Or use wpa_gui

# -----------------------------------
# Packages
# -----------------------------------

# Configure git
# Create new SSH key for device: https://help.github.com/articles/connecting-to-github-with-ssh/
# Add GPG key from backup: https://gist.github.com/chrisroos/1205934

# Select all
sudo pacman -S base-devel

# Install yay
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si

# Disable package compression
sudo vim /etc/maklepkg.conf
# [...]
# #PKGEXT='.pkg.tar.xz'
# PKGEXT='.pkg.tar'
# [...]

# Install sway
yay termite sway

# Install all other packages
pacman -Rsu $(comm -23 <(pacman -Qq | sort) <(sort pkglist-clean.txt))

cd ~
mkdir Projects
mkdir Github
git clone git@github.com:joenye/Dotfiles.git
.~/Dotfiles/install.sh
git clone git@github.com:joenye/_Dotfiles.git
.~/_Dotfiles/install.sh

# Configure brightnessctl
sudo chmod u+s /usr/bin/brightnessctl

# Configure volume
systemctl --user enable pulseaudio.service
systemctl --user start pulseuadio.service
pactl list sinks short

# Configure TLP
# Set SATA_LINKPWR_ON_BAT=max_performance
sudo vim /etc/default/tlp

# Configure thinkfan
sudo modprobe thinkpad_acpi
sudo modprobe acpi_call
sudo echo "START=yes" > /etc/default/thinkfan
# => Copy thinkfan.conf into /etc/thinkfan.conf
sudo sensors-detect --auto
sudo systemctl enable thinkfan
sudo systemctl enable lm_sensors
# ExecStartPre=/sbin/modprobe thinkpad_acpi
# https://www.reddit.com/r/debian/comments/77d2br/thinkfan_fails_to_load_at_boot_but_works_fine/
sudo vim /usr/lib/systemd/system/thinkfan.service

# Configure vim: enter (neo)vim and run :PlugInstall

# Configure bluetooth
sudo usermod -a -G lp joenye
# ControllerMode=bredr
# AutoEnable=true
sudo vim /etc/bluetooth/main.conf
sudo systemctl enable bluetooth.service
sudo systemctl start bluetooth.service

# Optional: configure CUPS for Brother HL-L2365DW printer
yay brother-cups-wrapper-laser
yay brother-hll2360d
yay nss-mdns
# Change hosts line to include before resolve:
# mdns_minimal [NOTFOUND=return]
sudo sytemctl enable avahi-daemon.service
sudo systemctl start avahi-daemon.service
sudo vim /etc/nsswitch.conf
# Add wheel to SystemGroup line
sudo vim /etc/cups/cups-files.conf
sudo systemctl start org.cups.cupsd.service
sudo systemctl enable org.cups.cupsd.service
# We use IP address rather than hostname:
# https://wiki.archlinux.org/index.php/CUPS/Printer-specific_problems#Network_printers
# 1. Ensure printer is 192.168.0.12 and static DHCP address. Also printer is very
# unreliable is 5Ghz connection is on the router simultaneously with a 2.4Ghz connection
# 2. Add printer: http://localhost:631/ -> Add Printer
# 3. Other Network Printers -> Internet Printing Protocol (ipp)
# 4. Connection ipp://192.168.0.12/ipp/port1
# 5. Select Brother-HLL2360D Series PPD
# 6. Set default options (e.g. DuplexTumble) and set as server default
# For printing out code with syntax highlighting:
yay enscript
# enscript -2rB --line-numbers --font=Courier8 -p out.ps --highlight=python -c <file.py>
# lpr output.ps

# Prevent opening lid resuming sleep
sudo cat <<EOT > /etc/systemd/system/disable-lid.service
[Unit]
Description=Prevent opening the lid waking from sleep

[Service]
ExecStart=/bin/sh -c '/bin/echo LID > /proc/acpi/wakeup'

[Install]
WantedBy=multi-user.target
EOT
sudo systemctl start disable-lid.service
sudo systemctl enable disable-lid.service

# systemd-boot pacman hook
yay systemd-boot-pacman-hook

# -----------------------------------
# Snapshots
# -----------------------------------

sudo systemctl enable snapper-cleanup.timer
sudo systemctl enable snapper-timeline.timer

sudo umount /.snapshots
sudo rm -r /.snapshots
sudo snapper -c root create-config /
# Re-mount @snapshots to /.snapshots as per fstab
sudo mount -a
sudo chmod 750 /.snapshots

sudo umount /home/.snapshots
sudo rm -r /home/.snapshots
sudo snapper -c home create-config /home
# Remove auto-created subvolume
sudo rm -r /home/.snapshots
# Re-mount @snapshots to /.snapshots as per fstab
sudo mount -a
sudo chmod 750 /home/.snapshots

# Update /etc/snapper/configs/{root,home}:
# TIMELINE_MIN_AGE="1800"
# TIMELINE_LIMIT_HOURLY="5"
# TIMELINE_LIMIT_DAILY="7"
# TIMELINE_LIMIT_WEEKLY="0"
# TIMELINE_LIMIT_MONTHLY="0"
# TIMELINE_LIMIT_YEARLY="0"
