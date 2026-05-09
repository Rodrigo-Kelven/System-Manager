# Linux System Manager v2.0

Script unificado de **atualização, limpeza e diagnóstico** para sistemas Linux baseados em Debian, Ubuntu, CentOS e Fedora.

---

## Origem

Este script é resultado da fusão e melhoria de dois scripts anteriores:

| Script original | Função |
|---|---|
| `script_auto_update.sh` | Atualizava repositórios, pacotes e realizava full-upgrade via `apt` |
| `cleaner.sh` | Limpeza interativa do sistema com menu, dry-run e suporte multi-distro |

---

## Funcionalidades

### Atualização
- Atualização de repositórios (`apt update`, `dnf check-update`, `yum check-update`)
- Upgrade de pacotes instalados
- Full-upgrade / distro-sync
- Verificação automática de necessidade de reinicialização

### Limpeza
- Arquivos temporários em `/tmp` (não acessados há mais de 2 dias)
- Cache de usuários em `/home/*/.cache/`
- Cache de pacotes e pacotes órfãos (`autoremove` + `clean`)
- Logs antigos do journal (>7 dias) e arquivos `.gz`/`.old` (>30 dias)
- Lixeira de todos os usuários
- Thumbnails

### Diagnóstico
- Resumo do sistema: OS, kernel, uptime, RAM, gerenciador de pacotes
- Uso de disco (antes e depois de cada operação)
- Busca de arquivos grandes (>500MB), sem cruzar filesystems (`-xdev`)
- Listagem de serviços habilitados

### Histórico
- Visualização paginada do log `/var/log/system_manager.log` diretamente pelo menu
- Usa `less` (posicionado no final) se disponível, ou `cat` como fallback

---

## Uso

```bash
# Requer root
sudo ./system_manager.sh           # Menu interativo
sudo ./system_manager.sh --auto    # Manutenção completa sem interação (ideal para cron)
sudo ./system_manager.sh --dry-run # Simula todas as operações sem executar nada
sudo ./system_manager.sh --help    # Exibe as opções disponíveis
```

### Menu interativo

```
╔══════════════════════════════════╗
║     Linux System Manager v2.0    ║
╚══════════════════════════════════╝
 [ Atualização ]
  1) Atualizar sistema completo

 [ Limpeza ]
  2) Limpeza completa
  3) Limpar /tmp
  4) Limpar cache de pacotes + órfãos
  5) Limpar logs antigos
  6) Limpar lixeira e thumbnails

 [ Diagnóstico ]
  7) Ver arquivos grandes (>500MB)
  8) Ver serviços habilitados
  9) Resumo do sistema

 [ Manutenção ]
 10) Manutenção completa (update + clean)

 [ Histórico ]
 11) Ver log de operações

  0) Sair
```

---

## Melhorias em relação aos scripts originais

### Bugs corrigidos
- `apt clean -y` → `apt clean` (`clean` não aceita o flag `-y`)
- `sudo` redundante dentro de script que já exige root
- `eval "$@"` substituído por `bash -c "$cmd"` (mais seguro contra expansão indevida)
- Globs `rm -rf /home/*/.cache/*` substituídos por `find` com caminhos explícitos (seguro com espaços em nomes de diretórios)

### Novas funcionalidades
- Flag `--auto` para execução não interativa (ex: agendamento via cron)
- Flag `--help` com instruções de uso
- Exibição do espaço livre **antes e depois** de cada operação
- Aviso e prompt de reinicialização quando necessário após updates
- Resumo do sistema exibido na inicialização
- `find_large_files` com `-xdev` (não cruza filesystems)
- Limpeza adicional de logs rotativos antigos (`.gz`, `.old`)
- Log salvo em `/var/log/system_manager.log` com permissão `600` (somente root)
- Saída colorida no terminal para melhor legibilidade
- Visualização do histórico de operações diretamente pelo menu (opção 11)

---

## Logs

Todas as operações são registradas em:

```
/var/log/system_manager.log
```

O arquivo é criado automaticamente com permissão `600` (leitura restrita ao root).

---

## Compatibilidade

| Distro | Gerenciador | Suporte |
|---|---|---|
| Ubuntu / Debian | `apt` | Completo |
| Fedora / RHEL 8+ | `dnf` | Completo |
| CentOS / RHEL 7 | `yum` | Completo |
| Outros | — | Diagnóstico apenas |

---

## Agendamento com cron

Para executar manutenção completa automaticamente toda semana (domingo às 3h):

```bash
sudo crontab -e
```

```cron
0 3 * * 0 /home/kd6-cowboy/tools/system_manager.sh --auto >> /var/log/system_manager.log 2>&1
```
