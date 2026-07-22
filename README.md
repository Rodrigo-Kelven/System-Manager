# Linux System Manager v2.1

Ferramenta de **atualização, limpeza, diagnóstico e auditoria de segurança** para sistemas Linux baseados em Debian, Ubuntu, CentOS e Fedora.

Composta por dois arquivos com responsabilidades separadas:

| Arquivo | Responsabilidade |
|---|---|
| `system_manager.sh` | Atualização, limpeza, diagnóstico e menu interativo |
| `security_audit.sh` | Auditoria de segurança de pacotes (carregado como módulo) |

---

## Instalação

Os dois arquivos devem estar no **mesmo diretório**:

```
/seu/diretório/
├── system_manager.sh
└── security_audit.sh
```

```bash
chmod +x system_manager.sh security_audit.sh
```

---

## Uso

```bash
# Menu interativo
sudo ./system_manager.sh

# Manutenção completa sem interação (ideal para cron)
sudo ./system_manager.sh --auto

# Simula todas as operações sem executar nada
sudo ./system_manager.sh --dry-run

# Auditoria de segurança + relatório .md
sudo ./system_manager.sh --security-audit

# Auditoria + aplica correções automaticamente
sudo ./system_manager.sh --security-fix

# Auditoria standalone (sem o manager)
sudo ./security_audit.sh
sudo ./security_audit.sh --dry-run
sudo ./security_audit.sh --apply-fixes

# Limpeza avançada: snap disabled + kernels antigos + configs residuais
sudo ./system_manager.sh --advanced-clean

# Ou individualmente
sudo ./system_manager.sh --clean-snap       # só revisões snap disabled
sudo ./system_manager.sh --clean-kernels    # só kernels antigos (apt)
sudo ./system_manager.sh --clean-rc         # só pacotes com config residual (apt)

# Combinado com --dry-run, apenas simula (nada é removido)
sudo ./system_manager.sh --advanced-clean --dry-run
```

---

## Menu interativo

```
╔══════════════════════════════════╗
║     Linux System Manager v2.1    ║
╚══════════════════════════════════╝
 [ Atualização ]
  1) Atualizar sistema completo

 [ Limpeza ]
  2) Limpeza completa
  3) Limpar /tmp
  4) Limpar cache de pacotes + orfãos
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

 [ 🔐 Segurança ]
 12) Auditoria de segurança de pacotes
 13) Auditoria rápida (DRY-RUN)

 [ 🧹 Limpeza Avançada ]
 14) Remover revisões snap desabilitadas
 15) Remover kernels antigos (apt)
 16) Remover pacotes com config residual (apt)
 17) Executar as 3 limpezas avançadas

  0) Sair
```

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
- Lixeira de todos os usuários e root
- Thumbnails

### Diagnóstico
- Resumo do sistema: OS, kernel, uptime, RAM, gerenciador de pacotes
- Uso de disco antes e depois de cada operação
- Busca de arquivos grandes (>500MB) sem cruzar filesystems (`-xdev`)
- Listagem de serviços habilitados

### Histórico
- Visualização paginada do log `/var/log/system_manager.log` pelo menu
- Usa `less` (posicionado no final) ou `cat` como fallback

---

## Auditoria de Segurança (`security_audit.sh`)

O módulo de segurança executa em **6 fases sequenciais** e gera um relatório `.md` completo.

### Fase 1 — Coleta de dados
- Lista todos os pacotes instalados via `dpkg-query` / `rpm -qa`
- Identifica pacotes com versão mais recente disponível

### Fase 2 — Análise de vulnerabilidades (3 fontes combinadas)

| Fonte | Mecanismo | Cobertura |
|---|---|---|
| **A — Gerenciador nativo** | `apt-get -s dist-upgrade` + `grep security` / `dnf updateinfo security` | Security updates já empacotados pela distro |
| **B — OSV.dev** | API REST por pacote com versão instalada | CVEs globais com CVSS score e versão de correção |
| **C — Distro tracker** | Ubuntu USN (`ubuntu.com/security/cves.json`) ou Debian Security Tracker | CVEs específicos da distro não cobertos pelo OSV |

Os resultados das 3 fontes são **deduplicados por pacote**, mantendo a entrada de maior severidade.

### Fase 3 — EOL dinâmico via endoflife.date
- Consulta `https://endoflife.date/api/{produto}.json` em tempo real para cada pacote relevante instalado
- Detecta ciclos com EOL confirmado (boolean `true` ou data já passada)
- Alerta para ciclos com EOL em até 180 dias
- Complementado por lista estática para protocolos inseguros sem entrada no endoflife.date (telnet, rsh, ftp, ntp legado)

### Fase 4 — Aplicação de correções com pinning de versão
Ao invés de `apt upgrade` genérico, resolve a **versão mínima segura** para cada pacote vulnerável:

1. Busca a versão onde o CVE foi corrigido (campo `fixed` do OSV)
2. Encontra a menor versão `>= cve_fixed_version` disponível no repositório local via `dpkg --compare-versions`
3. Fallback para versão mais recente do repositório de segurança (`grep security` no `apt-cache madison`)
4. Último fallback: versão mais recente disponível

O install usa `apt-get install pkg=versão_exata`, não `apt upgrade`.

### Fase 5 — Simulação antes de aplicar
Antes de qualquer correção, executa `apt-get -s install pkg=versão` (simulação sem alterações):
- Detecta conflitos de dependência (`conflict`, `broken`, `held back`)
- Conta remoções implícitas — se mais de 3 pacotes seriam removidos, eleva o risco
- Pacotes com conflito detectado são **pulados automaticamente** e registrados no relatório como `SKIPPED`

### Fase 5 — Ciclo recursivo de verificação
Após aplicar correções, re-verifica o sistema até 3 vezes para garantir que nenhuma vulnerabilidade secundária foi introduzida. Para quando o sistema converge (zero pendências) ou atinge o limite de ciclos.

### Fase 6 — Relatório Markdown
Gerado em `/var/log/security_audit/security_report_YYYYMMDD_HHMMSS.md` com:

- Sumário executivo com contadores
- Score de risco global 0–100 (Baixo / Médio / Alto / Crítico)
- Tabela de CVEs com fonte, severidade, CVSS score, versão instalada e versão segura resolvida
- Tabela de pacotes EOL com data de fim de suporte e substituto recomendado
- Tabela de pacotes desatualizados com análise de estabilidade e resultado da simulação
- Tabela de correções aplicadas com método de seleção de versão
- Checklist de hardening (SSH root login, autenticação por chave, firewall)

---

## Limpeza Avançada (Snap disabled / Kernels antigos / Configs residuais)

Além da limpeza padrão, o menu **[ 🧹 Limpeza Avançada ]** automatiza três liberações de espaço que normalmente exigem comandos manuais:

### 1. Revisões `disabled` do Snap
Equivalente a rodar `snap list --all`, filtrar as linhas marcadas como `disabled` e remover cada uma com `snap remove <pacote> --revision=<N>`. O script lista as revisões encontradas, pede confirmação (pulada em `--dry-run`, `--auto` ou quando chamado via flag de CLI) e remove todas automaticamente.

### 2. Kernels antigos (apt)
Mantém apenas o **kernel em execução** (`uname -r`) e o **mais recente instalado**; todos os demais `linux-image-*` (e seus `linux-headers-*` correspondentes) são listados e purgados com `apt-get purge`, seguido de `autoremove`.

### 3. Pacotes com configuração residual (`rc`)
Pacotes que aparecem como `rc` em `dpkg -l` (removidos, mas com arquivos de configuração remanescentes) são detectados via `awk '/^rc/{print $2}'` e purgados com `apt-get purge`.

Todas as três operações:
- Respeitam `--dry-run` (apenas mostram o que seria removido)
- Pedem confirmação interativa no menu, exceto em `--auto` ou quando disparadas por flag de CLI (já são um consentimento explícito, seguindo o mesmo padrão de `--security-fix`)
- Registram cada pacote/revisão removido no `system_manager.log`

---

## Logs e relatórios

| Arquivo | Conteúdo |
|---|---|
| `/var/log/system_manager.log` | Operações de atualização, limpeza e diagnóstico |
| `/var/log/security_audit/audit.log` | Log detalhado de cada execução da auditoria |
| `/var/log/security_audit/security_report_*.md` | Relatórios de auditoria em Markdown |

Todos os arquivos de log são criados com permissão `600` (leitura restrita ao root).

---

## Compatibilidade

| Distro | Gerenciador | system_manager | security_audit |
|---|---|---|---|
| Ubuntu / Debian | `apt` | Completo | Completo (USN + OSV + nativo) |
| Fedora / RHEL 8+ | `dnf` | Completo | Parcial (OSV + nativo) |
| CentOS / RHEL 7 | `yum` | Completo | Parcial (OSV + nativo) |
| openSUSE | `zypper` | Completo | Parcial (OSV) |

### Dependências opcionais do módulo de segurança

| Ferramenta | Impacto se ausente |
|---|---|
| `curl` | CVE lookup online e verificação EOL desabilitados |
| `jq` | Parsing JSON reduzido a grep básico |
| `bc` | Classificação por CVSS score desabilitada |

---

## Agendamento com cron

```bash
sudo crontab -e
```

```cron
# Manutenção completa toda segunda-feira às 3h
0 3 * * 1 /caminho/para/system_manager.sh --auto >> /var/log/system_manager.log 2>&1

# Auditoria de segurança todo domingo às 2h
0 2 * * 0 /caminho/para/system_manager.sh --security-audit >> /var/log/security_audit/audit.log 2>&1
```
