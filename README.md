# arch-deploy

Instaladores Arch Linux / CachyOS das minhas máquinas. Cada script apaga o
disco escolhido e entrega o sistema pronto: LUKS2 + Secure Boot + TPM e Sway
com os [dotfiles Shadow Materia](https://github.com/jeffinshadow/sway-dotfiles).

| Script | Máquina |
|---|---|
| `deploy-latios.sh` | `shadowtec-latios` — Dell Latitude 7280 (thin client + kit de TI). Arch, btrfs + snapper, TPM + PIN |
| `deploy-giratina.sh` | `shadowtec-giratina` — Xeon E5-2680 v4 + RX 580 (servidor 24/7 + jogos). CachyOS v3, ext4, TPM sem PIN com UKI assinada |

## Uso (no live ISO do Arch)

```bash
curl -fsSLO https://scripts.shadow.tec.br/deploy-<máquina>.sh
chmod +x deploy-<máquina>.sh && ./deploy-<máquina>.sh
```

Antes de rodar, leia o cabeçalho do script: ajustes de BIOS e a ordem do
pós-instalação (Secure Boot → TPM) estão lá.

## Atualizar o script no servidor

```bash
for s in latios giratina; do
  curl -fsSLo <pasta-do-site>/deploy-$s.sh \
    https://raw.githubusercontent.com/jeffinshadow/arch-deploy/main/deploy-$s.sh
done
```
