#!/usr/bin/env bash
#
# ================================================================
#  Instalação Arch Linux — "shadowtec-latios"
#  Target: Dell Latitude 7280 — i7-7600U, HD 620, 16GB, FHD 12.5",
#          Wi-Fi Intel 8265/8275
#  Uso: thin client + kit de campo de TI (discos/redes/infra)
#  Interface: Sway (Wayland) + apps GTK, tema Shadow Materia
# ================================================================
#
#  Derivado do deploy do desktop (deployoriginal.sh). Mantém:
#    * GPT + ESP 1G + raiz em LUKS2 (argon2id), systemd-boot
#    * initramfs systemd + sd-encrypt, Secure Boot (sbctl), zram
#  Muda:
#    * Raiz em btrfs (@, @home, @snapshots, @var_log, @pkg) + snapper
#      com snap-pac (snapshot antes/depois de cada pacman) e o helper
#      'snapshot-rollback' pra voltar a raiz pra um snapshot
#    * TPM2 + PIN (helper tpm-enroll) em vez de TPM puro
#    * Kernels linux (padrão) + linux-lts (fallback)
#    * Intel (mesa/vulkan-intel/intel-media-driver), TLP + thermald,
#      fwupd com EFI assinada pro Secure Boot
#    * Sway + greetd/tuigreet; dotfiles em repo próprio (sway-dotfiles)
#    * Kit de TI: discos, hardware, redes, acesso remoto
#  Removido: multilib/lib32, Steam e gaming, KDE/SDDM, AMD/CoreCtrl,
#            governor 'performance'
#
# ORDEM CERTA DAS COISAS:
#   A. BIOS (F2 no logo da Dell):
#      - System Configuration → SATA Operation: AHCI
#        (em "RAID On" o instalador NÃO enxerga o SSD NVMe)
#      - Secure Boot → Secure Boot Enable: DESLIGADO (a ISO não boota com ele)
#      - Security → TPM 2.0 Security: TPM On (+ Attestation/Key Storage)
#      - General → Advanced Boot Options: desmarque Legacy Option ROMs
#      - Power Management → Primary Battery Charge Configuration:
#        Custom, 50% → 80% (preserva a bateria; o TLP também tenta)
#   B. Boot pela ISO. Rede:
#        cabo:  ping -c 2 archlinux.org
#        Wi-Fi: iwctl station wlan0 connect "NOME_DA_REDE"
#   C. curl -fsSLO https://scripts.shadow.tec.br/deploy-latios.sh
#      chmod +x deploy-latios.sh && ./deploy-latios.sh
#      (se a pasta sway-dotfiles/ estiver ao lado do script, ela é usada;
#       senão os dotfiles são clonados de DOTFILES_REPO)
#   D. Depois do 1º boot (a senha do LUKS será pedida na tela):
#        1) BIOS: Secure Boot → Expert Key Management → Enable Custom Mode,
#           apague a PK (Delete) → firmware entra em Setup Mode
#        2) sudo secureboot-enroll
#        3) BIOS: Secure Boot Enable → LIGADO
#        4) sudo tpm-enroll   → define o PIN; o boot passa a pedir só o PIN
#
# O script é IDEMPOTENTE até a etapa de particionamento — depois disso,
# o disco selecionado é APAGADO sem retorno.
#

set -euo pipefail

# ================================================================
# CONFIGURAÇÕES FIXAS
# ================================================================
HOSTNAME="shadowtec-latios"
USERNAME="shadow"
TIMEZONE="America/Sao_Paulo"
LOCALE_PRIMARY="pt_BR.UTF-8"
KEYMAP="br-abnt2"
CONSOLE_FONT="ter-v24n"          # terminus: legível no FHD de 12.5"
EFI_SIZE="1G"
LUKS_NAME="cryptroot"
BTRFS_OPTS="noatime,compress=zstd:1,space_cache=v2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_LOCAL="$SCRIPT_DIR/sway-dotfiles"
DOTFILES_REPO="https://github.com/jeffinshadow/sway-dotfiles"

# Cores pra log
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[X]${NC} $*"; exit 1; }

# ================================================================
# VALIDAÇÕES INICIAIS
# ================================================================
[[ $EUID -eq 0 ]] || fail "Rode como root."
[[ -d /sys/firmware/efi ]] || fail "Sistema não está em modo UEFI. Esta build é UEFI-only."
ping -c 1 -W 3 archlinux.org &>/dev/null \
    || fail "Sem internet. Cabo, ou Wi-Fi: iwctl station wlan0 connect \"REDE\""

if [[ -d /sys/class/tpm/tpm0 ]]; then
    ok "TPM detectado em /sys/class/tpm/tpm0."
else
    warn "TPM NÃO detectado. A instalação segue normal, mas o 'tpm-enroll'"
    warn "não vai funcionar até o TPM aparecer (BIOS → Security → TPM 2.0 Security)."
fi

ok "Validações OK: root, UEFI e rede."

# ================================================================
# COLETA INTERATIVA
# ================================================================
echo
echo "=== Discos disponíveis ==="
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E "nvme|sd|vd" || true
echo

read -rp "Digite o dispositivo alvo (ex: /dev/nvme0n1 ou /dev/sda): " DISK
[[ -b "$DISK" ]] || fail "Dispositivo $DISK não existe."

echo
warn "ATENÇÃO: o dispositivo $DISK será TOTALMENTE APAGADO."
warn "Todos os dados nele serão perdidos PERMANENTEMENTE."
read -rp "Digite 'CONFIRMO' (maiúsculas) para prosseguir: " CONFIRM
[[ "$CONFIRM" == "CONFIRMO" ]] || fail "Cancelado pelo usuário."

# Senha do LUKS (destrava o disco até o TPM+PIN; depois vira fallback)
echo
echo "Senha de criptografia do disco (LUKS):"
echo "  - será pedida em todo boot ATÉ você rodar 'sudo tpm-enroll';"
echo "  - depois disso o boot pede só o PIN do TPM, e esta senha vira o"
echo "    fallback (BIOS/Secure Boot mudou? ela é pedida de novo)."
while true; do
    read -rsp "Senha do LUKS: " LUKS_PASS; echo
    read -rsp "Confirme a senha do LUKS: " LUKS_PASS2; echo
    [[ "$LUKS_PASS" == "$LUKS_PASS2" && -n "$LUKS_PASS" ]] && break
    warn "Senhas não conferem ou estão vazias. Tente novamente."
done

# Senha do usuário
echo
while true; do
    read -rsp "Senha do usuário '$USERNAME': " USER_PASS; echo
    read -rsp "Confirme a senha de '$USERNAME': " USER_PASS2; echo
    [[ "$USER_PASS" == "$USER_PASS2" && -n "$USER_PASS" ]] && break
    warn "Senhas não conferem ou estão vazias. Tente novamente."
done

# Senha do root
while true; do
    read -rsp "Senha do root: " ROOT_PASS; echo
    read -rsp "Confirme a senha do root: " ROOT_PASS2; echo
    [[ "$ROOT_PASS" == "$ROOT_PASS2" && -n "$ROOT_PASS" ]] && break
    warn "Senhas não conferem ou estão vazias. Tente novamente."
done

ok "Configurações coletadas."

# ================================================================
# CALCULAR NOMES DE PARTIÇÃO (NVMe usa sufixo 'p1', SATA não)
# ================================================================
if [[ "$DISK" =~ nvme ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# ================================================================
# PRÉ-INSTALAÇÃO (ambiente live)
# ================================================================
log "Configurando teclado e relógio do live..."
loadkeys "$KEYMAP"

log "Otimizando pacman do live (parallel downloads + color)..."
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
pacman -Sy --noconfirm
timedatectl set-ntp true

log "Atualizando mirrorlist (Brasil, ordenado por velocidade)..."
# git: nem toda ISO traz (o clone dos dotfiles roda no chroot, mas fica de reserva)
pacman -S --noconfirm --needed reflector git
reflector \
    --country Brazil \
    --age 12 \
    --protocol https \
    --sort rate \
    --latest 20 \
    --save /etc/pacman.d/mirrorlist
ok "Mirrorlist gerado."

# ================================================================
# PARTICIONAMENTO
# ================================================================
log "Limpando assinaturas e tabela de partições de $DISK..."
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
partprobe "$DISK"
udevadm settle

log "Criando GPT: ESP (${EFI_SIZE}) + ROOT/LUKS (restante)..."
sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI"  "$DISK"
sgdisk -n 2:0:0           -t 2:8309 -c 2:"LUKS" "$DISK"
partprobe "$DISK"
udevadm settle

# ================================================================
# LUKS2 + BTRFS
# ================================================================
log "Criando container LUKS2 em $ROOT_PART (AES-XTS, argon2id)..."
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat \
    --type luks2 \
    --pbkdf argon2id \
    --batch-mode \
    --key-file=- \
    "$ROOT_PART"

log "Abrindo container como /dev/mapper/$LUKS_NAME..."
printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" "$LUKS_NAME"

log "Formatando ESP (FAT32) e raiz (btrfs)..."
mkfs.fat -F32 -n EFI "$EFI_PART"
mkfs.btrfs -f -L ROOT "/dev/mapper/$LUKS_NAME"

# Layout plano: snapshots ficam FORA de @, então dá pra trocar o @ inteiro
# por um snapshot (snapshot-rollback). /var/log e o cache do pacman ficam
# fora dos snapshots de propósito (logs sobrevivem a rollback; pacotes
# não incham os snapshots).
log "Criando subvolumes btrfs..."
mount "/dev/mapper/$LUKS_NAME" /mnt
for sv in @ @home @snapshots @var_log @pkg; do
    btrfs subvolume create "/mnt/$sv"
done
umount /mnt

log "Montando subvolumes em /mnt..."
mount -o "$BTRFS_OPTS,subvol=@" "/dev/mapper/$LUKS_NAME" /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log,var/cache/pacman/pkg}
mount -o "$BTRFS_OPTS,subvol=@home"      "/dev/mapper/$LUKS_NAME" /mnt/home
mount -o "$BTRFS_OPTS,subvol=@snapshots" "/dev/mapper/$LUKS_NAME" /mnt/.snapshots
mount -o "$BTRFS_OPTS,subvol=@var_log"   "/dev/mapper/$LUKS_NAME" /mnt/var/log
mount -o "$BTRFS_OPTS,subvol=@pkg"       "/dev/mapper/$LUKS_NAME" /mnt/var/cache/pacman/pkg
# umask 0077: random-seed e loader não ficam legíveis por todo mundo
mount -o umask=0077 "$EFI_PART" /mnt/boot
ok "Partições montadas."

# ================================================================
# PACSTRAP — instalação base
# ================================================================
log "Executando pacstrap (pode demorar)..."
pacstrap -K /mnt \
    base base-devel \
    linux linux-headers \
    linux-lts linux-lts-headers \
    linux-firmware \
    intel-ucode \
    cryptsetup tpm2-tss tpm2-tools sbctl \
    btrfs-progs snapper \
    nano vim git sudo wget curl \
    man-db man-pages texinfo \
    networkmanager firewalld wireless-regdb \
    efibootmgr \
    dosfstools e2fsprogs ntfs-3g \
    zram-generator \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
    bluez bluez-utils \
    reflector pacman-contrib \
    zsh terminus-font

ok "Sistema base instalado."

# ================================================================
# FSTAB
# ================================================================
log "Gerando fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
# Sem subvolid: monta por NOME (subvol=/@). É isso que permite trocar o @
# por um snapshot no rollback sem mexer no fstab.
sed -i -E 's/,?subvolid=[0-9]+//' /mnt/etc/fstab
ok "fstab gerado."

# ================================================================
# UUID DO CONTAINER LUKS (pra cmdline do systemd-boot)
# ================================================================
LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
[[ -n "$LUKS_UUID" ]] || fail "Não consegui obter UUID do container LUKS."

# ================================================================
# SCRIPT DE CHROOT
# Heredoc com aspas: nada é expandido aqui fora. As variáveis vão pelo
# deploy.env (printf %q = seguro pra qualquer caractere).
# ================================================================
log "Gravando script de configuração interna..."

{
    for v in HOSTNAME USERNAME TIMEZONE LOCALE_PRIMARY KEYMAP CONSOLE_FONT LUKS_UUID LUKS_NAME; do
        printf '%s=%q\n' "$v" "${!v}"
    done
} > /mnt/root/deploy.env

cat > /mnt/root/chroot-setup.sh <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source /root/deploy.env

# Se algo falhar no meio, não deixa o NOPASSWD do paru pra trás
trap 'rm -f /etc/sudoers.d/99-paru-install' EXIT

echo "[chroot] Timezone e relógio..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

echo "[chroot] Locale e console..."
sed -i 's/^#pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=$LOCALE_PRIMARY" > /etc/locale.conf
printf 'KEYMAP=%s\nFONT=%s\n' "$KEYMAP" "$CONSOLE_FONT" > /etc/vconsole.conf

echo "[chroot] Hostname e hosts..."
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

echo "[chroot] Região do Wi-Fi (BR)..."
sed -i 's/^#WIRELESS_REGDOM="BR"/WIRELESS_REGDOM="BR"/' /etc/conf.d/wireless-regdom

echo "[chroot] pacman.conf e makepkg..."
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf
sed -i 's/^MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf
pacman -Sy

echo "[chroot] mkinitcpio: hooks systemd + sd-encrypt (LUKS/TPM) + microcode..."
# Sem 'fsck': btrfs não usa fsck no boot
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo "[chroot] Criando usuário $USERNAME..."
# wheel = sudo. Grupos de hardware (uucp, video, wireshark) entram depois
# dos pacotes que os criam.
useradd -m -G wheel -s /bin/zsh "$USERNAME"

echo "[chroot] Habilitando sudo para grupo wheel..."
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c

echo "[chroot] Instalando systemd-boot..."
bootctl install || bootctl install --graceful

cat > /boot/loader/loader.conf <<LOADER
default      arch.conf
timeout      3
console-mode max
editor       no
LOADER

# Kernel cmdline:
#  - LUKS via sd-encrypt; discard = TRIM através do dm-crypt;
#    no-*-workqueue = menos latência no SSD
#  - tpm2-device=auto: antes do enroll só cai no fallback de senha, sem erro
#  - rootflags=subvol=@: raiz é o subvolume @ (rollback troca o @)
#  - mem_sleep_default=deep: S3 de verdade (se o firmware não tiver, é ignorado)
KERNEL_OPTS="rd.luks.name=$LUKS_UUID=$LUKS_NAME rd.luks.options=$LUKS_UUID=discard,no-read-workqueue,no-write-workqueue,tpm2-device=auto root=/dev/mapper/$LUKS_NAME rootflags=subvol=@ rw quiet loglevel=3 udev.log_level=3 rd.udev.log_level=3 systemd.show_status=auto rd.systemd.show_status=auto mem_sleep_default=deep nowatchdog"

# microcode vai embutido no initramfs (hook 'microcode')
cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options $KERNEL_OPTS
ENTRY

cat > /boot/loader/entries/arch-lts.conf <<ENTRY
title   Arch Linux LTS (Fallback)
linux   /vmlinuz-linux-lts
initrd  /initramfs-linux-lts.img
options $KERNEL_OPTS
ENTRY

# Hook do pacman pra atualizar o systemd-boot sozinho em updates do systemd.
# O hook zz-sbctl.hook (do pacote sbctl) roda DEPOIS e reassina os binários.
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/95-systemd-boot.hook <<'HOOK'
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Gracefully upgrading systemd-boot...
When = PostTransaction
Exec = /usr/bin/systemctl restart systemd-boot-update.service
HOOK

echo "[chroot] Configurando ZRAM..."
cat > /etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
ZRAM

cat > /etc/sysctl.d/99-zram.conf <<'SYSCTL'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
SYSCTL

# ----------------------------------------------------------------
# PACOTES
# ----------------------------------------------------------------
DRIVERS=(
    mesa vulkan-intel intel-media-driver libva-utils vulkan-tools intel-gpu-tools
)
ENERGIA=(
    tlp thermald upower fwupd fwupd-efi bolt alsa-utils
)
SESSAO=(
    greetd greetd-tuigreet
    sway swaybg swayidle swaylock waybar rofi mako kanshi swayosd
    xorg-xwayland xdg-desktop-portal-wlr xdg-desktop-portal-gtk
    polkit-gnome gnome-keyring seahorse libsecret
    grim slurp swappy wl-clipboard cliphist wl-mirror jq libnotify
    brightnessctl playerctl gammastep
    network-manager-applet blueman pavucontrol
    xdg-user-dirs xdg-utils xdg-terminal-exec
    nwg-look nwg-displays
)
TEMA=(
    adw-gtk-theme papirus-icon-theme qt6ct qt5-wayland qt6-wayland
    noto-fonts noto-fonts-emoji noto-fonts-cjk inter-font
    ttf-liberation ttf-dejavu
    ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono
)
APPS=(
    ghostty ghostty-nautilus
    nautilus nautilus-python sushi gvfs gvfs-smb gvfs-mtp gvfs-nfs
    file-roller 7zip unzip zip
    loupe papers gnome-text-editor gnome-calculator
    gnome-disk-utility baobab
    webp-pixbuf-loader ffmpegthumbnailer
    firefox firefox-i18n-pt-br chromium
    remmina freerdp libvncserver
    libreoffice-fresh libreoffice-fresh-pt-br hunspell hunspell-en_us
    cups cups-pdf system-config-printer ipp-usb avahi nss-mdns
    solaar
)
SHELL_CLI=(
    zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search
    zsh-completions starship fastfetch
    btop htop tmux mosh openssh rsync rclone bash-completion ncdu
)
TI_DISCOS=(
    gparted smartmontools nvme-cli hdparm sdparm
    testdisk ddrescue partclone fsarchiver clonezilla
    exfatprogs xfsprogs f2fs-tools lvm2 mdadm mtools
    wimlib chntpw
    lshw dmidecode inxi hwinfo usbutils pciutils lm_sensors
    s-tui stress-ng memtester fio iotop
)
TI_REDES=(
    nmap zenmap wireshark-qt tcpdump arp-scan
    mtr traceroute iperf3 bind whois ipcalc speedtest-cli
    ethtool iw wavemon nethogs iftop bmon
    lldpd picocom minicom tftp-hpa dnsmasq net-snmp wakeonlan
    openbsd-netcat socat
    smbclient cifs-utils nfs-utils sshfs
    wireguard-tools networkmanager-openvpn networkmanager-openconnect
)

echo "[chroot] Instalando drivers, Sway, apps e kit de TI..."
pacman -S --noconfirm --needed \
    "${DRIVERS[@]}" "${ENERGIA[@]}" "${SESSAO[@]}" "${TEMA[@]}" \
    "${APPS[@]}" "${SHELL_CLI[@]}" "${TI_DISCOS[@]}" "${TI_REDES[@]}"

echo "[chroot] Grupos extras do $USERNAME (serial, backlight, captura)..."
# uucp      = /dev/ttyUSB* (cabo console de switch/roteador)
# video     = brilho da tela pelo swayosd
# wireshark = captura sem rodar o Wireshark como root
usermod -aG uucp,video,wireshark "$USERNAME"

# ----------------------------------------------------------------
# CONFIGURAÇÃO DE HARDWARE / ENERGIA
# ----------------------------------------------------------------
echo "[chroot] TLP (energia do i7-7600U)..."
cat > /etc/tlp.d/10-latios.conf <<'TLP'
# Latitude 7280 — i7-7600U (intel_pstate + HWP)
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power
# Turbo desligado na bateria: menos calor e bem mais autonomia.
# Se sentir falta, troque pra 1.
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0

PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto

WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

USB_AUTOSUSPEND=1
USB_EXCLUDE_BTUSB=1
USB_EXCLUDE_PHONE=1

# Limite de carga (se o kernel expuser pra Dell; senão vale o da BIOS)
START_CHARGE_THRESH_BAT0=50
STOP_CHARGE_THRESH_BAT0=80
TLP

echo "[chroot] DNS: systemd-resolved (DNS por VPN) + Avahi (mDNS/impressoras)..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/10-mdns-avahi.conf <<'RESOLVED'
# mDNS fica com o Avahi (CUPS e nss-mdns usam ele)
[Resolve]
MulticastDNS=no
RESOLVED
sed -i -E '/^hosts:/{/mdns_minimal/!s/resolve/mdns_minimal [NOTFOUND=return] resolve/}' /etc/nsswitch.conf

echo "[chroot] greetd + tuigreet..."
cat > /etc/greetd/config.toml <<GREETD
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-user-session --asterisks --greeting '$HOSTNAME' --cmd sway"
user = "greeter"
GREETD
install -d -o greeter -g greeter /var/cache/tuigreet

# gnome-keyring destrava junto com o login (senhas, chaves SSH)
grep -q pam_gnome_keyring /etc/pam.d/greetd || cat >> /etc/pam.d/greetd <<'PAM'
auth       optional     pam_gnome_keyring.so
session    optional     pam_gnome_keyring.so auto_start
PAM
grep -q pam_gnome_keyring /etc/pam.d/passwd || \
    echo 'password   optional     pam_gnome_keyring.so' >> /etc/pam.d/passwd

# ----------------------------------------------------------------
# SECURE BOOT (chaves + assinaturas) e fwupd
# ----------------------------------------------------------------
echo "[chroot] Secure Boot: criando chaves e assinando binários..."
# O CADASTRO das chaves no firmware fica pro pós-boot (sudo secureboot-enroll),
# porque exige a BIOS em Setup Mode. Binários assinados bootam normal com SB off.
sbctl create-keys
sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi
sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
sbctl sign -s /boot/vmlinuz-linux
sbctl sign -s /boot/vmlinuz-linux-lts
# fwupd: atualização de BIOS Dell via LVFS com Secure Boot ligado
sbctl sign -s -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi
mkdir -p /etc/fwupd
if ! grep -q '^\[uefi_capsule\]' /etc/fwupd/fwupd.conf 2>/dev/null; then
    printf '\n[uefi_capsule]\nDisableShimForSecureBoot=true\n' >> /etc/fwupd/fwupd.conf
fi
sbctl verify || true

# ----------------------------------------------------------------
# SNAPPER
# ----------------------------------------------------------------
echo "[chroot] Snapper (config 'root')..."
# Config escrita à mão: o 'snapper create-config' tentaria criar o
# subvolume .snapshots dentro do @, mas aqui ele já é o @snapshots.
mkdir -p /etc/snapper/configs
cp /usr/share/snapper/config-templates/default /etc/snapper/configs/root
set_snapper() {
    local key="$1" val="$2" f=/etc/snapper/configs/root
    if grep -q "^$key=" "$f"; then
        sed -i "s|^$key=.*|$key=\"$val\"|" "$f"
    else
        echo "$key=\"$val\"" >> "$f"
    fi
}
set_snapper SUBVOLUME              "/"
set_snapper FSTYPE                 "btrfs"
set_snapper ALLOW_GROUPS           "wheel"
set_snapper SYNC_ACL               "yes"
set_snapper NUMBER_LIMIT           "10"
set_snapper NUMBER_LIMIT_IMPORTANT "5"
set_snapper TIMELINE_CREATE        "yes"
set_snapper TIMELINE_LIMIT_HOURLY  "4"
set_snapper TIMELINE_LIMIT_DAILY   "7"
set_snapper TIMELINE_LIMIT_WEEKLY  "2"
set_snapper TIMELINE_LIMIT_MONTHLY "0"
set_snapper TIMELINE_LIMIT_YEARLY  "0"
sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root"/' /etc/conf.d/snapper
chown root:wheel /.snapshots
chmod 750 /.snapshots

# ----------------------------------------------------------------
# SERVIÇOS
# ----------------------------------------------------------------
echo "[chroot] Habilitando serviços..."
systemctl enable NetworkManager.service
systemctl enable systemd-resolved.service
systemctl enable firewalld.service
systemctl enable greetd.service
systemctl enable bluetooth.service
systemctl enable tlp.service
systemctl enable thermald.service
systemctl enable systemd-timesyncd.service
systemctl enable systemd-oomd.service
systemctl enable systemd-boot-update.service
systemctl enable avahi-daemon.service
systemctl enable cups.socket
systemctl enable fwupd-refresh.timer
systemctl enable paccache.timer
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer
# TLP controla rádios; o systemd-rfkill brigaria com ele
systemctl mask systemd-rfkill.service systemd-rfkill.socket
# Agente SSH do gnome-keyring pra todos os usuários
systemctl --global enable gcr-ssh-agent.socket \
    || echo "[chroot] AVISO: gcr-ssh-agent.socket não encontrado (agente SSH do keyring)"
# Sob demanda (NÃO sobem no boot): lldpd, dnsmasq, tftpd

# ----------------------------------------------------------------
# PARU + AUR
# ----------------------------------------------------------------
echo "[chroot] Instalando paru (AUR helper) como $USERNAME..."
# Permite sudo sem senha temporariamente pro pacman -U
echo '%wheel ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/99-paru-install
chmod 440 /etc/sudoers.d/99-paru-install

su - "$USERNAME" -c "
    cd /tmp &&
    rm -rf paru-bin &&
    git clone https://aur.archlinux.org/paru-bin.git &&
    cd paru-bin &&
    makepkg -si --noconfirm
"

cat > /etc/paru.conf <<'PARU'
[options]
BottomUp
SudoLoop
CleanAfter
NewsOnUpgrade
CombinedUpgrade
UpgradeMenu
PARU

# Um por um: se um pacote do AUR quebrar, os outros seguem.
AUR=(
    ttf-google-sans            # UI
    ttf-google-sans-code-nf    # terminal (Nerd Font)
    bibata-cursor-theme-bin
    papirus-folders
    hunspell-pt-br             # corretor do LibreOffice
    f3                         # detecta pendrive/cartão falsificado
    ventoy-bin                 # pendrive multiboot
    winbox                     # MikroTik
)
AUR_FALHOU=()
for pkg in "${AUR[@]}"; do
    pkg="${pkg%%#*}"; pkg="${pkg// /}"
    [[ -n "$pkg" ]] || continue
    echo "[chroot] AUR: $pkg"
    su - "$USERNAME" -c "paru -S --needed --noconfirm --skipreview $pkg" \
        || AUR_FALHOU+=("$pkg")
done
rm -f /etc/sudoers.d/99-paru-install

if ((${#AUR_FALHOU[@]})); then
    printf '%s\n' "${AUR_FALHOU[@]}" > "/home/$USERNAME/AUR-PENDENTE.txt"
    chown "$USERNAME:$USERNAME" "/home/$USERNAME/AUR-PENDENTE.txt"
    echo "[chroot] AVISO: falharam no AUR: ${AUR_FALHOU[*]} (lista em ~/AUR-PENDENTE.txt)"
fi

# Pastas azuis no Papirus (como no KDE)
command -v papirus-folders &>/dev/null && papirus-folders -C blue --theme Papirus-Dark || true

# snap-pac por ÚLTIMO: senão cada pacman acima gerava um par de snapshots
echo "[chroot] snap-pac (snapshot automático em todo pacman)..."
pacman -S --noconfirm --needed snap-pac

echo "[chroot] Tudo configurado dentro do chroot."
CHROOT_SCRIPT

chmod +x /mnt/root/chroot-setup.sh

# ================================================================
# EXECUTA O SCRIPT DENTRO DO CHROOT
# ================================================================
log "Entrando em arch-chroot pra configurar o sistema..."
arch-chroot /mnt /root/chroot-setup.sh

# resolv.conf → stub do systemd-resolved (dentro do chroot o arquivo
# está bind-montado, por isso é feito aqui fora)
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

# ================================================================
# SENHAS — fora do heredoc: aspas/caracteres especiais não quebram nada
# ================================================================
log "Definindo senhas de root e $USERNAME..."
printf '%s:%s\n' root "$ROOT_PASS" | arch-chroot /mnt chpasswd
printf '%s:%s\n' "$USERNAME" "$USER_PASS" | arch-chroot /mnt chpasswd
unset LUKS_PASS LUKS_PASS2 USER_PASS USER_PASS2 ROOT_PASS ROOT_PASS2

# ================================================================
# DOTFILES (repo independente: o mesmo serve pro desktop)
# ================================================================
log "Instalando dotfiles (Shadow Materia / Sway)..."
DOT_DST="/mnt/home/$USERNAME/.dotfiles"
DOT_OK=true
rm -rf "$DOT_DST"
if [[ -f "$DOTFILES_LOCAL/install.sh" ]]; then
    cp -a "$DOTFILES_LOCAL" "$DOT_DST"
    ok "Dotfiles copiados de $DOTFILES_LOCAL"
# Clone pelo git do sistema INSTALADO (vem no pacstrap), já como o usuário:
# não depende do que a ISO traz e o dono dos arquivos já sai certo.
elif arch-chroot /mnt su - "$USERNAME" -c "git clone --depth 1 '$DOTFILES_REPO' ~/.dotfiles"; then
    ok "Dotfiles clonados de $DOTFILES_REPO"
else
    DOT_OK=false
    warn "Não achei os dotfiles (nem local, nem $DOTFILES_REPO)."
    warn "O Sway sobe com a config padrão. Depois do boot:"
    warn "  git clone $DOTFILES_REPO ~/.dotfiles && ~/.dotfiles/install.sh"
fi
if $DOT_OK; then
    arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.dotfiles"
    arch-chroot /mnt su - "$USERNAME" -c "/home/$USERNAME/.dotfiles/install.sh --yes --host $HOSTNAME" \
        || warn "install.sh dos dotfiles terminou com erro — rode de novo depois do boot."
fi

# ================================================================
# HELPERS DE PÓS-INSTALAÇÃO (Secure Boot, TPM, rollback)
# ================================================================
log "Instalando helpers: secureboot-enroll, tpm-enroll, snapshot-rollback..."
mkdir -p /mnt/usr/local/sbin

cat > /mnt/usr/local/sbin/secureboot-enroll <<'HELPER_SB'
#!/usr/bin/env bash
# Cadastra as chaves do sbctl no firmware. Rodar com a BIOS em Setup Mode.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Rode com sudo."; exit 1; }

if ! bootctl status 2>/dev/null | grep -q 'Secure Boot:.*(setup)'; then
    echo "ERRO: o firmware não está em Setup Mode."
    echo "Na BIOS da Dell: Secure Boot → Expert Key Management →"
    echo "  marque 'Enable Custom Mode', selecione PK e apague (Delete)."
    echo "Depois disso, rode este script de novo."
    exit 1
fi

echo "Cadastrando chaves próprias + certificados Microsoft..."
echo "(o -m mantém os certificados da Microsoft: firmware de dispositivos,"
echo " docks e Option ROMs assinados por ela continuam carregando)"
sbctl enroll-keys -m
sbctl sign-all || true
sbctl verify || true

echo
echo "Pronto. Agora: reinicie, ATIVE o Secure Boot na BIOS e confirme com:"
echo "    bootctl status   (deve mostrar 'Secure Boot: enabled (user)')"
echo "Em seguida, rode:  sudo tpm-enroll"
HELPER_SB
chmod 755 /mnt/usr/local/sbin/secureboot-enroll

cat > /mnt/usr/local/sbin/tpm-enroll <<'HELPER_TPM'
#!/usr/bin/env bash
# Cadastra TPM2 + PIN no LUKS (PCR 7). No boot, pede só o PIN.
# Notebook roubado não destrava sozinho: sem o PIN, o TPM não libera a
# chave, e erros repetidos acionam a proteção anti-força-bruta do TPM.
# A senha do LUKS continua valendo como fallback.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Rode com sudo."; exit 1; }
[[ -e /dev/tpmrm0 || -e /dev/tpm0 ]] || { echo "TPM não encontrado (/dev/tpm*). Confira a BIOS."; exit 1; }

if ! bootctl status 2>/dev/null | grep -qi 'Secure Boot: enabled'; then
    echo "AVISO: Secure Boot NÃO está ativo. O ideal é cadastrar o TPM só com o"
    echo "estado FINAL do Secure Boot definido — o PCR 7 muda quando ele muda,"
    echo "e aí o PIN para de funcionar (cai na senha do LUKS)."
    read -rp "Continuar mesmo assim? [s/N] " r
    [[ "${r,,}" == "s" ]] || exit 1
fi

DEV=$(blkid -t TYPE=crypto_LUKS -o device | head -n1)
[[ -n "$DEV" ]] || { echo "Nenhum volume LUKS encontrado."; exit 1; }
echo "Volume LUKS: $DEV"
echo "Primeiro a senha do LUKS (autoriza), depois o PIN novo (2x)."
echo "O PIN pode ter letras e números."

# Remove enroll antigo do TPM se existir (torna o script re-executável)
systemd-cryptenroll --wipe-slot=tpm2 "$DEV" 2>/dev/null || true
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=yes "$DEV"

echo
echo "Feito. O próximo boot pede o PIN em vez da senha do LUKS."
echo "Se a BIOS for atualizada ou o Secure Boot mudar, volta a pedir a senha"
echo "(comportamento esperado) — aí é só rodar 'sudo tpm-enroll' de novo."
HELPER_TPM
chmod 755 /mnt/usr/local/sbin/tpm-enroll

cat > /mnt/usr/local/sbin/snapshot-rollback <<'HELPER_RB'
#!/usr/bin/env bash
# snapshot-rollback <N> — troca a raiz (@) pelo snapshot N do snapper.
#
# O @ atual é renomeado (não apagado) e um snapshot gravável do N vira o
# novo @. Vale no próximo boot. /home, /var/log e o cache do pacman não
# são tocados.
#
# Se o sistema NÃO boota, faça o mesmo pelo live ISO:
#   cryptsetup open /dev/<part-luks> cryptroot
#   mount -o subvolid=5 /dev/mapper/cryptroot /mnt
#   mv /mnt/@ /mnt/@.quebrado
#   btrfs subvolume snapshot /mnt/@snapshots/<N>/snapshot /mnt/@
#   umount /mnt && reboot
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Rode com sudo."; exit 1; }

N="${1:-}"
if [[ -z "$N" ]]; then
    snapper -c root list
    echo
    echo "Uso: sudo snapshot-rollback <número>"
    exit 1
fi
[[ "$N" =~ ^[0-9]+$ ]] || { echo "Número de snapshot inválido: $N"; exit 1; }

DEV=$(findmnt -no SOURCE / | sed 's/\[.*\]$//')
TOP=$(mktemp -d /tmp/btrfs-top.XXXXXX)
mount -o subvolid=5 "$DEV" "$TOP"
trap 'umount "$TOP" 2>/dev/null; rmdir "$TOP" 2>/dev/null' EXIT

SNAP="$TOP/@snapshots/$N/snapshot"
[[ -d "$SNAP" ]] || { echo "Snapshot $N não existe."; exit 1; }

echo "Snapshot escolhido:"
snapper -c root list | awk -v n="$N" 'NR<=2 || $1==n'
echo

# Kernel: o kernel fica na ESP (fora do snapshot). Se o snapshot for de
# antes de uma atualização de kernel, os módulos dele não batem.
MISMATCH=()
for k in /boot/vmlinuz-*; do
    ver=$(file -bL "$k" | grep -oP 'version \K\S+' || true)
    if [[ -n "$ver" && ! -d "$SNAP/usr/lib/modules/$ver" ]]; then
        MISMATCH+=("$(basename "$k") ($ver)")
    fi
done
if ((${#MISMATCH[@]})); then
    echo "AVISO: o snapshot não tem os módulos destes kernels da ESP:"
    printf '   - %s\n' "${MISMATCH[@]}"
    echo "Depois do rollback, boote pelo kernel que NÃO está na lista (normalmente"
    echo "o LTS) e rode: sudo pacman -S linux linux-lts  (reinstala e alinha)."
    echo
fi

read -rp "Digite ROLLBACK pra trocar a raiz pelo snapshot $N: " c
[[ "$c" == "ROLLBACK" ]] || { echo "Cancelado."; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
mv "$TOP/@" "$TOP/@.antes-rollback-$TS"
btrfs subvolume snapshot "$SNAP" "$TOP/@"

echo
echo "Feito. Reinicie pra entrar no snapshot $N."
echo "Quando estiver tudo certo, apague a raiz antiga:"
echo "   sudo mount -o subvolid=5 $DEV /mnt"
echo "   sudo btrfs subvolume delete /mnt/@.antes-rollback-$TS && sudo umount /mnt"
HELPER_RB
chmod 755 /mnt/usr/local/sbin/snapshot-rollback

# ================================================================
# SNAPSHOT DA INSTALAÇÃO LIMPA
# ================================================================
log "Criando snapshot da instalação limpa..."
arch-chroot /mnt snapper --no-dbus -c root create -c number --userdata important=yes -d "Instalação limpa (deploy-latios)" \
    || warn "Não consegui criar o snapshot inicial (crie depois: sudo snapper create -d base)."

# ================================================================
# LIMPEZA E FINALIZAÇÃO
# ================================================================
log "Removendo scripts temporários de chroot..."
rm -f /mnt/root/chroot-setup.sh /mnt/root/deploy.env

AUR_PENDENTE=false
[[ -f "/mnt/home/$USERNAME/AUR-PENDENTE.txt" ]] && AUR_PENDENTE=true

log "Desmontando partições e fechando o LUKS..."
umount -R /mnt
cryptsetup close "$LUKS_NAME"

ok "===================================================="
ok "Instalação concluída com sucesso!"
ok "===================================================="
echo
echo "  Hostname : $HOSTNAME"
echo "  Usuário  : $USERNAME (zsh)"
echo "  Disco    : $DISK  (LUKS2: $ROOT_PART → btrfs)"
echo "  Kernels  : linux (padrão) + linux-lts (fallback)"
echo
echo "  Próximos passos após o reboot (a senha do LUKS será pedida no boot):"
echo "    1. BIOS: Secure Boot → Expert Key Management → Enable Custom Mode,"
echo "       apague a PK. Boot, login como '$USERNAME' e: sudo secureboot-enroll"
echo "    2. BIOS: Secure Boot Enable → LIGADO. Confira: bootctl status"
echo "    3. sudo tpm-enroll  → define o PIN do boot."
echo "    4. BIOS da Dell pelo Linux: fwupdmgr refresh && fwupdmgr update"
echo "    5. Confira: cat /sys/power/mem_sleep  (deve ter [deep])"
echo "               sudo tlp-stat -b           (limite de carga 50–80%)"
echo "    6. Redes confiáveis na zona 'home' do firewall (libera mDNS/SMB):"
echo "         nmcli connection modify \"NOME\" connection.zone home"
echo "    7. Snapshots: snapper list | rollback: sudo snapshot-rollback <N>"
echo "    8. Ferramentas de bancada sob demanda (não sobem no boot):"
echo "         sudo systemctl start lldpd && lldpcli show neighbors"
echo "         dnsmasq / in.tftpd → abra a porta no firewall só enquanto usar"
echo "    9. Solaar: o G305 aparece sozinho ao plugar o receptor."
if $AUR_PENDENTE; then
    echo "   10. Alguns pacotes do AUR falharam: veja ~/AUR-PENDENTE.txt"
fi
echo
warn "Digite 'reboot' quando estiver pronto. Lembre de remover o pendrive."
