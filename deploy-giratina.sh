#!/usr/bin/env bash
#
# ================================================================
#  Instalação CachyOS — "shadowtec-giratina"
#  Target: Xeon E5-2680 v4 (x86-64-v3) + 16GB DDR4 ECC + RX 580,
#          placa QIYIDA X99-H9S (BIOS AMI), Realtek RTL8111
#  Uso: servidor 24/7 (docker compose via Cloudflare Tunnel) +
#       desktop/jogos de vez em quando + processamento via SSH
#  Interface: Sway (Wayland) + apps GTK, tema Shadow Materia
# ================================================================
#
#  Irmão do deploy-latios.sh. Mantém:
#    * GPT + ESP 1G + raiz em LUKS2 (argon2id), systemd-boot
#    * initramfs systemd + sd-encrypt, Secure Boot (sbctl)
#    * Sway + greetd/tuigreet; dotfiles em repo próprio (sway-dotfiles)
#  Muda:
#    * CachyOS: repositórios v3 (pacotes compilados pra x86-64-v3),
#      pacman do CachyOS, cachyos-settings (zram, sysctl, ananicy-cpp...)
#    * Kernels linux-cachyos (padrão) + linux-cachyos-lts (fallback)
#    * Raiz em ext4, SEM snapshots (sem nobreak: journal do ext4 + escrita
#      no disco mais frequente). Recuperação: kernel LTS + cache do pacman
#    * TPM2 SEM PIN (helper tpm-enroll): volta sozinho de queda de luz.
#      Por isso o boot é por UKI assinada (kernel + initramfs + cmdline num
#      .efi só): ninguém troca o initramfs nem a cmdline sem quebrar a
#      assinatura, e o TPM não libera a chave
#    * AMD (mesa/vulkan-radeon + lib32), Steam/gamemode/mangohud, LACT
#    * Docker (compose em /srv/docker/<serviço>), cloudflared, tmux
#    * sshd só em 127.0.0.1 (o acesso vem pelo túnel), firewalld sem
#      nenhuma porta de entrada, suspensão desligada
#    * Disco de jogos (Steam) intacto, montado em /mnt/jogos
#
# ORDEM CERTA DAS COISAS:
#   A. BIOS (Del no logo):
#      - Secure Boot → Key Management → "Reset To Setup Mode" (ou
#        "Delete All Secure Boot Variables"). Em Setup Mode a ISO boota
#        e o instalador já cadastra as chaves novas no firmware.
#        Sem essa opção: desligue o Secure Boot e rode 'secureboot-enroll'
#        depois do 1º boot.
#      - CSM: DESLIGADO (só UEFI)
#      - TPM (PTT/fTPM ou módulo): ligado
#      - Energia: "Restore on AC Power Loss" / "State After G3" → Power On
#        (a máquina religa sozinha quando a luz volta)
#   B. Boot pela ISO do Arch (recente) ou do CachyOS, com cabo de rede:
#        ping -c 2 archlinux.org
#   C. curl -fsSLO https://scripts.shadow.tec.br/deploy-giratina.sh
#      chmod +x deploy-giratina.sh && ./deploy-giratina.sh
#      (se a pasta sway-dotfiles/ estiver ao lado do script, ela é usada;
#       senão os dotfiles são clonados de DOTFILES_REPO)
#   D. Depois do 1º boot (a senha do LUKS será pedida na tela):
#        1) BIOS: Secure Boot → LIGADO (as chaves já foram cadastradas;
#           se não foram, rode antes: sudo secureboot-enroll)
#        2) bootctl status   → "Secure Boot: enabled (user)"
#        3) sudo tpm-enroll  → daí em diante o disco abre sozinho
#
# O script é IDEMPOTENTE até a etapa de particionamento — depois disso,
# o disco selecionado é APAGADO sem retorno.
#

set -euo pipefail

# ================================================================
# CONFIGURAÇÕES FIXAS
# ================================================================
HOSTNAME="shadowtec-giratina"
USERNAME="shadow"
TIMEZONE="America/Sao_Paulo"
LOCALE_PRIMARY="pt_BR.UTF-8"
KEYMAP="br-abnt2"
CONSOLE_FONT="ter-v20n"
EFI_SIZE="1G"
LUKS_NAME="cryptroot"
EXT4_OPTS="noatime"

# Disco do sistema esperado (só pra conferência: outro modelo pede
# confirmação extra). O outro NVMe é a biblioteca Steam e NÃO é tocado.
SYSTEM_DISK_MODEL="WDS480G2G0C"
GAMES_MOUNT="/mnt/jogos"

# Chave de assinatura dos pacotes do CachyOS
CACHYOS_KEY="F3B607488DB35A47"

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

# Partição N de um disco (NVMe usa sufixo 'pN', SATA não)
part() { [[ "$1" =~ [0-9]$ ]] && echo "${1}p$2" || echo "${1}$2"; }

# ================================================================
# VALIDAÇÕES INICIAIS
# ================================================================
[[ $EUID -eq 0 ]] || fail "Rode como root."
[[ -d /sys/firmware/efi ]] || fail "Sistema não está em modo UEFI. Esta build é UEFI-only."
ping -c 1 -W 3 archlinux.org &>/dev/null || fail "Sem internet. Confira o cabo de rede."

/lib/ld-linux-x86-64.so.2 --help | grep -q 'x86-64-v3 (supported' \
    || fail "CPU sem suporte a x86-64-v3: os repositórios v3 do CachyOS não servem aqui."

if [[ -d /sys/class/tpm/tpm0 ]]; then
    ok "TPM detectado em /sys/class/tpm/tpm0."
else
    warn "TPM NÃO detectado. A instalação segue normal, mas o 'tpm-enroll'"
    warn "não vai funcionar até o TPM aparecer (confira a BIOS)."
fi

SB_SETUP=false
if command -v sbctl &>/dev/null || pacman -Sy --noconfirm --needed sbctl &>/dev/null; then
    if sbctl status --json 2>/dev/null | grep -q '"setup_mode": *true'; then
        SB_SETUP=true
        ok "Firmware em Setup Mode: as chaves do Secure Boot serão cadastradas agora."
    else
        warn "Firmware NÃO está em Setup Mode: as chaves ficam pra depois"
        warn "(sudo secureboot-enroll, com a BIOS em Setup Mode)."
    fi
fi

ok "Validações OK: root, UEFI, rede e x86-64-v3."

# ================================================================
# COLETA INTERATIVA
# ================================================================
echo
echo "=== Discos disponíveis ==="
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN | grep -E "NAME|nvme|sd|vd" || true
echo
echo "Disco do sistema esperado: modelo $SYSTEM_DISK_MODEL (WD 480 GB)."
echo "O outro NVMe (biblioteca Steam) NÃO deve ser escolhido."
echo

read -rp "Digite o dispositivo alvo (ex: /dev/nvme0n1): " DISK
[[ -b "$DISK" ]] || fail "Dispositivo $DISK não existe."
DISK_MODEL=$(lsblk -dno MODEL "$DISK" | xargs)

if [[ "$DISK_MODEL" != *"$SYSTEM_DISK_MODEL"* ]]; then
    echo
    warn "O modelo de $DISK é '$DISK_MODEL', não o esperado ($SYSTEM_DISK_MODEL)."
    warn "Se este for o disco da Steam, os jogos serão PERDIDOS."
    read -rp "Digite 'OUTRO DISCO' pra usar $DISK mesmo assim: " CONFIRM
    [[ "$CONFIRM" == "OUTRO DISCO" ]] || fail "Cancelado pelo usuário."
fi

echo
warn "ATENÇÃO: o dispositivo $DISK ($DISK_MODEL) será TOTALMENTE APAGADO."
warn "Todos os dados nele serão perdidos PERMANENTEMENTE."
read -rp "Digite 'CONFIRMO' (maiúsculas) para prosseguir: " CONFIRM
[[ "$CONFIRM" == "CONFIRMO" ]] || fail "Cancelado pelo usuário."

# Disco de jogos: partições ext4 FORA do disco alvo
GAMES_PART=""
CANDIDATAS=()
while read -r nome tipo; do
    [[ "$tipo" == part ]] || continue
    [[ "$(lsblk -dpno PKNAME "$nome")" == "$DISK" ]] && continue
    [[ "$(lsblk -dno FSTYPE "$nome")" == ext4 ]] && CANDIDATAS+=("$nome")
done < <(lsblk -lpno NAME,TYPE)
if ((${#CANDIDATAS[@]} == 1)); then
    c="${CANDIDATAS[0]}"
    echo
    echo "Partição ext4 em outro disco: $c ($(lsblk -dno SIZE,MODEL "$(lsblk -no PKNAME -p "$c")" | xargs))"
    read -rp "Montar em $GAMES_MOUNT (sem formatar)? [S/n] " r
    [[ "${r,,}" == "n" ]] || GAMES_PART="$c"
elif ((${#CANDIDATAS[@]} > 1)); then
    echo
    echo "Partições ext4 em outros discos:"
    printf '   %s\n' "${CANDIDATAS[@]}"
    read -rp "Qual montar em $GAMES_MOUNT (sem formatar)? Enter = nenhuma: " c
    if [[ -n "$c" ]]; then
        printf '%s\n' "${CANDIDATAS[@]}" | grep -qx "$c" || fail "$c não está na lista."
        GAMES_PART="$c"
    fi
fi
[[ -n "$GAMES_PART" ]] && ok "Disco de jogos: $GAMES_PART → $GAMES_MOUNT" \
                       || warn "Sem disco de jogos (dá pra montar depois)."

# Senha do LUKS (destrava o disco até o tpm-enroll; depois vira fallback)
echo
echo "Senha de criptografia do disco (LUKS):"
echo "  - será pedida em todo boot ATÉ você rodar 'sudo tpm-enroll';"
echo "  - depois disso o disco abre sozinho, e esta senha vira o fallback"
echo "    (BIOS/Secure Boot mudou? ela é pedida de novo). GUARDE-A."
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

EFI_PART=$(part "$DISK" 1)
ROOT_PART=$(part "$DISK" 2)

# ================================================================
# PRÉ-INSTALAÇÃO (ambiente live)
# ================================================================
log "Configurando teclado e relógio do live..."
loadkeys "$KEYMAP"
timedatectl set-ntp true

log "Otimizando pacman do live (parallel downloads + color)..."
sed -i -E 's/^#?ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf

log "Atualizando mirrorlist do Arch (Brasil, ordenado por velocidade)..."
# git: nem toda ISO traz (o clone dos dotfiles roda no chroot, mas fica de reserva)
pacman -Sy --noconfirm --needed reflector git
reflector \
    --country Brazil \
    --age 12 \
    --protocol https \
    --sort rate \
    --latest 20 \
    --save /etc/pacman.d/mirrorlist
ok "Mirrorlist gerado."

# ----------------------------------------------------------------
# Repositórios do CachyOS no live (o pacstrap usa a config daqui)
# Mesmo caminho do cachyos-repo.sh oficial: chave → pacman do CachyOS
# (entende 'Architecture = auto' como x86_64 + x86_64_v3) → repos v3
# acima dos do Arch.
# ----------------------------------------------------------------
if grep -q '^\[cachyos-v3\]' /etc/pacman.conf; then
    ok "Live já tem os repositórios v3 do CachyOS (ISO do CachyOS)."
else
    log "Importando a chave do CachyOS..."
    pacman-key --recv-keys "$CACHYOS_KEY" --keyserver keyserver.ubuntu.com \
        || pacman-key --recv-keys "$CACHYOS_KEY" --keyserver hkps://keys.openpgp.org \
        || fail "Não consegui baixar a chave do CachyOS ($CACHYOS_KEY)."
    pacman-key --lsign-key "$CACHYOS_KEY"

    log "Instalando pacman, chaves e mirrorlists do CachyOS no live..."
    # O pacman novo pode trazer o pacman.conf dele: guarda o do live
    cp /etc/pacman.conf /root/pacman.conf.live
    # Repo temporário (sem v3) só pra buscar essas peças
    # shellcheck disable=SC2016  # $repo é do pacman, não do shell
    printf '\n[cachyos]\nServer = https://mirror.cachyos.org/repo/x86_64/$repo\n' >> /etc/pacman.conf
    pacman -Sy --noconfirm cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos/pacman
    cp /root/pacman.conf.live /etc/pacman.conf

    # Repos do CachyOS ANTES do [core] (a ordem é a prioridade)
    awk '
        /^\[core\]$/ && !feito {
            print "[cachyos-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n"
            print "[cachyos-core-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n"
            print "[cachyos-extra-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n"
            print "[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n"
            feito = 1
        }
        { print }
    ' /etc/pacman.conf > /etc/pacman.conf.novo
    mv /etc/pacman.conf.novo /etc/pacman.conf
    sed -i -E 's/^#?Architecture *=.*/Architecture = auto/' /etc/pacman.conf
fi

# multilib (Steam, lib32-*): vai junto pro sistema pelo pacstrap -P
sed -i '/^#\[multilib\]$/,/^#Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm
log "Arquiteturas aceitas pelo pacman: $(pacman-conf Architecture | xargs)"
ok "Repositórios do CachyOS prontos."

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
# LUKS2 + EXT4
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

log "Formatando ESP (FAT32) e raiz (ext4)..."
mkfs.fat -F32 -n EFI "$EFI_PART"
mkfs.ext4 -F -L ROOT "/dev/mapper/$LUKS_NAME"

log "Montando partições em /mnt..."
mount -o "$EXT4_OPTS" "/dev/mapper/$LUKS_NAME" /mnt
mkdir -p /mnt/boot
# umask 0077: random-seed e loader não ficam legíveis por todo mundo
mount -o umask=0077 "$EFI_PART" /mnt/boot
ok "Partições montadas."

# ================================================================
# PACSTRAP — instalação base
# -K: chaveiro novo no sistema (a chave do CachyOS entra no chroot)
# -P: leva o pacman.conf do live (repos v3 + multilib)
# ================================================================
log "Executando pacstrap (pode demorar)..."
pacstrap -K -P /mnt \
    base base-devel \
    linux-cachyos linux-cachyos-headers \
    linux-cachyos-lts linux-cachyos-lts-headers \
    linux-firmware \
    intel-ucode \
    pacman cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist \
    cachyos-rate-mirrors cachyos-settings cachyos-hooks chwd \
    cryptsetup tpm2-tss tpm2-tools sbctl \
    nano vim git sudo wget curl \
    man-db man-pages texinfo \
    networkmanager firewalld \
    efibootmgr \
    dosfstools e2fsprogs ntfs-3g exfatprogs \
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

if [[ -n "$GAMES_PART" ]]; then
    GAMES_UUID=$(blkid -s UUID -o value "$GAMES_PART")
    [[ -n "$GAMES_UUID" ]] || fail "Não consegui obter UUID de $GAMES_PART."
    mkdir -p "/mnt$GAMES_MOUNT"
    # nofail: se o disco de jogos falhar, a máquina (e os serviços) sobem igual
    cat >> /mnt/etc/fstab <<FSTAB

# Disco de jogos (biblioteca Steam) — fora do LUKS, não é formatado pelo deploy
UUID=$GAMES_UUID  $GAMES_MOUNT  ext4  noatime,nofail,x-systemd.device-timeout=10s  0 2
FSTAB
fi
ok "fstab gerado."

# ================================================================
# UUID DO CONTAINER LUKS (pra cmdline)
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
    for v in HOSTNAME USERNAME TIMEZONE LOCALE_PRIMARY KEYMAP CONSOLE_FONT \
             LUKS_UUID LUKS_NAME CACHYOS_KEY SB_SETUP GAMES_MOUNT; do
        printf '%s=%q\n' "$v" "${!v}"
    done
} > /mnt/root/deploy.env

cat > /mnt/root/chroot-setup.sh <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source /root/deploy.env

# Se algo falhar no meio, não deixa o NOPASSWD do paru pra trás
trap 'rm -f /etc/sudoers.d/99-paru-install' EXIT

echo "[chroot] Chaveiro do pacman: Arch + CachyOS..."
pacman-key --populate archlinux cachyos
pacman-key --lsign-key "$CACHYOS_KEY"

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

echo "[chroot] makepkg..."
sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf
sed -i 's/^MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf
pacman -Sy

# ----------------------------------------------------------------
# BOOT: UKI assinada + systemd-boot
# ----------------------------------------------------------------
# Com o TPM abrindo o disco sem PIN, a cmdline e o initramfs NÃO podem
# ficar soltos na ESP (dava pra trocar e pegar a chave). Na UKI, kernel +
# initramfs + cmdline são um .efi só, assinado: mexeu, não boota com
# Secure Boot — e sem Secure Boot o PCR 7 muda e o TPM não libera nada.
echo "[chroot] mkinitcpio: hooks systemd + sd-encrypt (LUKS/TPM) + microcode..."
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

# Kernel cmdline (vai DENTRO da UKI):
#  - LUKS via sd-encrypt; discard = TRIM através do dm-crypt;
#    no-*-workqueue = menos latência no SSD
#  - tpm2-device=auto: antes do enroll só cai no fallback de senha, sem erro
#  - amdgpu.ppfeaturemask: libera clocks/tensão/ventoinha da RX 580 pro LACT
#  - nowatchdog: o watchdog não serve pra nada aqui (o cachyos-settings já
#    tira o iTCO_wdt e o nmi_watchdog)
mkdir -p /etc/kernel
echo "rd.luks.name=$LUKS_UUID=$LUKS_NAME rd.luks.options=$LUKS_UUID=discard,no-read-workqueue,no-write-workqueue,tpm2-device=auto root=/dev/mapper/$LUKS_NAME rw quiet loglevel=3 udev.log_level=3 rd.udev.log_level=3 systemd.show_status=auto rd.systemd.show_status=auto amdgpu.ppfeaturemask=0xffffffff nowatchdog" > /etc/kernel/cmdline

# Presets: uma UKI por kernel, sem imagem 'fallback' (o fallback é o LTS)
mkdir -p /boot/EFI/Linux
for k in linux-cachyos linux-cachyos-lts; do
    cat > "/etc/mkinitcpio.d/$k.preset" <<PRESET
# UKI assinada (deploy-giratina): kernel + initramfs + cmdline num .efi
ALL_kver="/boot/vmlinuz-$k"
PRESETS=('default')
default_uki="/boot/EFI/Linux/$k.efi"
PRESET
done
# initramfs soltos do pacstrap: não são mais usados
rm -f /boot/initramfs-*.img

echo "[chroot] Criando usuário $USERNAME..."
# wheel = sudo. Os outros grupos entram depois dos pacotes que os criam.
useradd -m -G wheel -s /bin/zsh "$USERNAME"

echo "[chroot] Habilitando sudo para grupo wheel..."
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c

echo "[chroot] Instalando systemd-boot..."
bootctl install || bootctl install --graceful

# UKIs em /EFI/Linux aparecem sozinhas no menu (não há entries .conf)
cat > /boot/loader/loader.conf <<'LOADER'
default      linux-cachyos.efi
timeout      3
console-mode max
editor       no
LOADER

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

# ----------------------------------------------------------------
# SECURE BOOT (chaves + assinaturas)
# ----------------------------------------------------------------
echo "[chroot] Secure Boot: criando chaves e gerando as UKIs assinadas..."
sbctl create-keys
mkinitcpio -P
sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi
sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
# -s: as UKIs entram no banco do sbctl, e o hook dele no mkinitcpio
# reassina a cada atualização de kernel
for k in linux-cachyos linux-cachyos-lts; do
    sbctl sign -s "/boot/EFI/Linux/$k.efi"
done
# fwupd (firmware de dispositivos) com Secure Boot ligado
sbctl sign -s -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi 2>/dev/null || true
mkdir -p /etc/fwupd
if [[ -d /usr/lib/fwupd ]] && ! grep -q '^\[uefi_capsule\]' /etc/fwupd/fwupd.conf 2>/dev/null; then
    printf '\n[uefi_capsule]\nDisableShimForSecureBoot=true\n' >> /etc/fwupd/fwupd.conf
fi

if [[ "$SB_SETUP" == true ]]; then
    echo "[chroot] Cadastrando as chaves no firmware (Setup Mode)..."
    # -m mantém os certificados da Microsoft: a ROM da RX 580 (vídeo no
    # boot) é assinada por ela — sem isso, tela preta com Secure Boot ligado
    sbctl enroll-keys -m \
        || echo "[chroot] AVISO: falhou o cadastro das chaves — rode 'sudo secureboot-enroll' depois."
fi
sbctl verify || true

# ----------------------------------------------------------------
# PACOTES
# ----------------------------------------------------------------
DRIVERS=(
    mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon
    vulkan-tools libva-utils radeontop
)
SISTEMA=(
    fwupd smartmontools
    ananicy-cpp cachyos-ananicy-rules   # habilitado lá embaixo; não depender de dependência
)
SESSAO=(
    greetd greetd-tuigreet
    sway swaybg swayidle swaylock waybar rofi mako kanshi swayosd autotiling-rs
    xorg-xwayland xdg-desktop-portal-wlr xdg-desktop-portal-gtk
    polkit-gnome gnome-keyring seahorse libsecret
    grim slurp swappy wl-clipboard cliphist wl-mirror jq libnotify
    playerctl gammastep
    network-manager-applet blueman pavucontrol
    xdg-user-dirs xdg-utils xdg-terminal-exec
    nwg-look nwg-displays
    # Reserva: são o terminal e o menu da config PADRÃO do sway. Se os
    # dotfiles não instalarem, o Super+Enter / Super+d ainda funcionam.
    foot wmenu
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
    gnome-disk-utility baobab mission-center snapshot
    webp-pixbuf-loader ffmpegthumbnailer
    firefox firefox-i18n-pt-br chromium
    gimp inkscape vlc vlc-plugins-all imagemagick chafa
    solaar
)
AUDIO=(
    # Tratamento do microfone (FIFINE): filtros, compressor, redução de ruído
    easyeffects calf lsp-plugins-lv2 rnnoise
)
JOGOS=(
    steam gamemode lib32-gamemode mangohud lib32-mangohud gamescope
    proton-cachyos-slr   # aparece na Steam: Propriedades → Compatibilidade
    lact                 # clocks/ventoinha/perfis da RX 580 (GTK)
)
SERVIDOR=(
    docker docker-compose docker-buildx
    cloudflared openssh tmux
    networkmanager-openvpn
)
SHELL_CLI=(
    zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search
    zsh-completions starship fastfetch
    btop htop ncdu iotop rsync rclone bash-completion
)
TI=(
    lm_sensors s-tui stress-ng nvme-cli inxi usbutils pciutils gparted
    mtr iperf3 nmap tcpdump bind whois ipcalc ethtool
)

echo "[chroot] Instalando drivers, Sway, apps, jogos e servidor..."
pacman -S --noconfirm --needed \
    "${DRIVERS[@]}" "${SISTEMA[@]}" "${SESSAO[@]}" "${TEMA[@]}" "${APPS[@]}" \
    "${AUDIO[@]}" "${JOGOS[@]}" "${SERVIDOR[@]}" "${SHELL_CLI[@]}" "${TI[@]}"

echo "[chroot] Grupos extras do $USERNAME (docker, gamemode)..."
# docker = 'docker compose' sem sudo (equivale a root: só o seu usuário)
usermod -aG docker "$USERNAME"
getent group gamemode &>/dev/null && usermod -aG gamemode "$USERNAME"

# ----------------------------------------------------------------
# AJUSTES DE SISTEMA
# ----------------------------------------------------------------
echo "[chroot] Escrita no disco mais frequente (sem nobreak)..."
# O cachyos-settings segura até 15 s de escrita na memória; aqui volta pro
# padrão do kernel (5 s): numa queda de luz, perde-se menos.
cat > /etc/sysctl.d/99-giratina.conf <<'SYSCTL'
vm.dirty_writeback_centisecs = 500
SYSCTL

echo "[chroot] Sem suspensão/hibernação (servidor 24/7)..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

echo "[chroot] DNS: systemd-resolved (o cachyos-settings já aponta o NM pra ele)..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/10-giratina.conf <<'RESOLVED'
# Sem mDNS/LLMNR: nada nesta máquina responde na rede local
[Resolve]
MulticastDNS=no
LLMNR=no
RESOLVED

echo "[chroot] Firewall: nenhuma porta de entrada (tudo vem pelo túnel)..."
# public já costuma ser a padrão, e aí o set dá ZONE_ALREADY_SET (erro)
[[ "$(firewall-offline-cmd --get-default-zone)" == public ]] \
    || firewall-offline-cmd --set-default-zone=public
firewall-offline-cmd --zone=public --remove-service=ssh || true

echo "[chroot] sshd: só local (127.0.0.1), só chave..."
cat > /etc/ssh/sshd_config.d/10-giratina.conf <<'SSHD'
# O acesso de fora vem pelo Cloudflare Tunnel, que entrega em localhost.
# A CA do Cloudflare Access (TrustedUserCAKeys) entra junto com o túnel.
ListenAddress 127.0.0.1
ListenAddress ::1
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
SSHD

echo "[chroot] Docker: logs com limite, containers sobrevivem a restart do daemon..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DOCKER'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
DOCKER
# Compose de cada serviço em /srv/docker/<nome>/ (dados em pastas normais)
install -d -m 755 -o "$USERNAME" -g "$USERNAME" /srv/docker

echo "[chroot] smartd: vigia os NVMe e avisa no desktop..."
cat > /usr/local/lib/smartd-notify <<'NOTIFY'
#!/usr/bin/env bash
# Chamado pelo smartd (-M exec) quando um disco dá sinal de problema.
# Manda notificação crítica pra toda sessão gráfica aberta (fica no mako
# até ser dispensada) e deixa um registro no journal.
logger -t smartd-notify -p user.crit "$SMARTD_DEVICE: $SMARTD_MESSAGE"
for dir in /run/user/*; do
    uid=$(basename "$dir")
    [[ -S "$dir/bus" ]] || continue
    user=$(id -nu "$uid" 2>/dev/null) || continue
    runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=$dir/bus" \
        notify-send -u critical -a smartd -i drive-harddisk \
        "Disco com problema: $SMARTD_DEVICE" "$SMARTD_MESSAGE" || true
done
NOTIFY
chmod 755 /usr/local/lib/smartd-notify
cat > /etc/smartd.conf <<'SMARTD'
# Todos os discos: saúde, erros e temperatura (aviso a 70 °C, crítico a 80 °C)
# <nomailer> = sem e-mail; o aviso vai pelo smartd-notify
DEVICESCAN -a -n standby,q -W 0,70,80 -m <nomailer> -M exec /usr/local/lib/smartd-notify
SMARTD

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
# SERVIÇOS
# ----------------------------------------------------------------
echo "[chroot] Habilitando serviços..."
systemctl enable NetworkManager.service
systemctl enable systemd-resolved.service
systemctl enable firewalld.service
systemctl enable greetd.service
systemctl enable bluetooth.service
systemctl enable systemd-timesyncd.service
systemctl enable systemd-oomd.service
systemctl enable systemd-boot-update.service
systemctl enable ananicy-cpp.service
systemctl enable fstrim.timer
systemctl enable fwupd-refresh.timer
# paccache: guarda as 3 últimas versões de cada pacote (o "rollback" daqui)
systemctl enable paccache.timer
systemctl enable docker.service
systemctl enable sshd.service
systemctl enable smartd.service
systemctl enable lactd.service
# Agente SSH do gnome-keyring pra todos os usuários
systemctl --global enable gcr-ssh-agent.socket \
    || echo "[chroot] AVISO: gcr-ssh-agent.socket não encontrado (agente SSH do keyring)"
# cloudflared: instalado, mas o túnel novo é criado depois (ver o final)

# ----------------------------------------------------------------
# AUR (o paru vem pronto do repositório do CachyOS)
# ----------------------------------------------------------------
echo "[chroot] paru (repositório do CachyOS)..."
pacman -S --noconfirm --needed paru

# Permite sudo sem senha temporariamente pro pacman -U
echo '%wheel ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/99-paru-install
chmod 440 /etc/sudoers.d/99-paru-install

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
    ttf-google-sans-code-vf    # terminal (ícones vêm do Symbols Nerd Font)
    bibata-cursor-theme-bin
    papirus-folders
    vesktop-bin                # Discord
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
# DOTFILES (repo independente: o mesmo serve pro notebook)
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
# HELPERS DE PÓS-INSTALAÇÃO (Secure Boot, TPM)
# ================================================================
log "Instalando helpers: secureboot-enroll, tpm-enroll..."
mkdir -p /mnt/usr/local/sbin

cat > /mnt/usr/local/sbin/secureboot-enroll <<'HELPER_SB'
#!/usr/bin/env bash
# Cadastra as chaves do sbctl no firmware. Rodar com a BIOS em Setup Mode.
# (O deploy já faz isso se a BIOS estava em Setup Mode na instalação.)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Rode com sudo."; exit 1; }

if ! bootctl status 2>/dev/null | grep -q 'Secure Boot:.*(setup)'; then
    echo "ERRO: o firmware não está em Setup Mode."
    echo "Na BIOS: Security → Secure Boot → Key Management →"
    echo "  'Reset To Setup Mode' (ou 'Delete All Secure Boot Variables')."
    echo "Depois disso, rode este script de novo."
    exit 1
fi

echo "Cadastrando chaves próprias + certificados Microsoft..."
echo "(o -m mantém os certificados da Microsoft: a ROM de vídeo da RX 580"
echo " é assinada por ela — sem isso, tela preta no boot)"
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
# Cadastra o TPM2 no LUKS, SEM PIN, preso ao Secure Boot (PCR 7): o disco
# abre sozinho no boot — a máquina volta de queda de luz sem ninguém.
# Se o Secure Boot for desligado, as chaves trocadas ou outro sistema
# bootar, o PCR 7 muda e o TPM não libera nada: cai na senha do LUKS.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Rode com sudo."; exit 1; }
[[ -e /dev/tpmrm0 || -e /dev/tpm0 ]] || { echo "TPM não encontrado (/dev/tpm*). Confira a BIOS."; exit 1; }

if ! bootctl status 2>/dev/null | grep -qi 'Secure Boot: enabled'; then
    echo "ERRO: Secure Boot NÃO está ativo."
    echo "Sem PIN, o que protege o disco é justamente o Secure Boot: cadastrar"
    echo "o TPM com ele desligado deixaria qualquer um abrir o disco."
    echo "Ligue o Secure Boot na BIOS (se preciso, antes: sudo secureboot-enroll)."
    exit 1
fi

DEV=$(blkid -t TYPE=crypto_LUKS -o device | head -n1)
[[ -n "$DEV" ]] || { echo "Nenhum volume LUKS encontrado."; exit 1; }
echo "Volume LUKS: $DEV"
echo "Digite a senha do LUKS pra autorizar."

# Remove enroll antigo do TPM se existir (torna o script re-executável)
systemd-cryptenroll --wipe-slot=tpm2 "$DEV" 2>/dev/null || true
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$DEV"

echo
echo "Feito. O próximo boot abre o disco sozinho."
echo "Se a BIOS for atualizada ou o Secure Boot mudar, volta a pedir a senha"
echo "(comportamento esperado) — aí é só rodar 'sudo tpm-enroll' de novo."
HELPER_TPM
chmod 755 /mnt/usr/local/sbin/tpm-enroll

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
echo "  Disco    : $DISK  (LUKS2: $ROOT_PART → ext4)"
echo "  Jogos    : ${GAMES_PART:-nenhum} → $GAMES_MOUNT"
echo "  Kernels  : linux-cachyos (padrão) + linux-cachyos-lts (fallback), UKIs assinadas"
echo
echo "  Próximos passos após o reboot (a senha do LUKS será pedida no boot):"
if [[ "$SB_SETUP" == true ]]; then
    echo "    1. BIOS: Secure Boot → LIGADO (as chaves já foram cadastradas)."
else
    echo "    1. BIOS em Setup Mode → boot → sudo secureboot-enroll → BIOS: Secure Boot LIGADO."
fi
echo "    2. Confira: bootctl status   (Secure Boot: enabled (user))"
echo "    3. sudo tpm-enroll  → daí em diante o disco abre sozinho."
echo "    4. BIOS: 'Restore on AC Power Loss' → Power On (se ainda não fez)."
echo "    5. Túnel novo do Cloudflare:"
echo "         sudo cloudflared service install <TOKEN>"
echo "       SSH pelo túnel com Cloudflare Access: a CA vai em"
echo "         /etc/ssh/sshd_config.d/ (TrustedUserCAKeys + AuthorizedPrincipalsFile)"
echo "    6. Serviços: /srv/docker/<nome>/compose.yml — portas sempre em"
echo "       127.0.0.1:PORTA (o túnel publica; o firewall não abre nada)."
echo "    7. Steam: Configurações → Armazenamento → adicione $GAMES_MOUNT/Steam."
echo "       Proton: Propriedades do jogo → Compatibilidade → proton-cachyos."
echo "    8. RX 580: abra o LACT pra perfil de clocks/ventoinha."
echo "    9. Atualização quebrou algo? Boot pelo LTS no menu e volte o pacote:"
echo "         sudo pacman -U /var/cache/pacman/pkg/<pacote-versão-anterior>.pkg.tar.zst"
if $AUR_PENDENTE; then
    echo "   10. Alguns pacotes do AUR falharam: veja ~/AUR-PENDENTE.txt"
fi
echo
warn "Digite 'reboot' quando estiver pronto. Lembre de remover o pendrive."
