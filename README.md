# arch-deploy

Instaladores Arch Linux das minhas máquinas. Cada script apaga o disco
escolhido e entrega o sistema pronto: LUKS2 + Secure Boot + TPM, btrfs com
snapshots, Sway com os [dotfiles Shadow Materia](https://github.com/jeffinshadow/sway-dotfiles).

| Script | Máquina |
|---|---|
| `deploy-latios.sh` | `shadowtec-latios` — Dell Latitude 7280 (thin client + kit de TI) |

## Uso (no live ISO do Arch)

```bash
curl -fsSLO https://scripts.shadow.tec.br/deploy-latios.sh
chmod +x deploy-latios.sh && ./deploy-latios.sh
```

Antes de rodar, leia o cabeçalho do script: ajustes de BIOS e a ordem do
pós-instalação (Secure Boot → TPM + PIN) estão lá.

## Atualizar o script no servidor

```bash
curl -fsSLo <pasta-do-site>/deploy-latios.sh \
  https://raw.githubusercontent.com/jeffinshadow/arch-deploy/main/deploy-latios.sh
```
