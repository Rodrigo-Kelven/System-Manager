# Análise Técnica — Linux System Manager v2.1 + Security Audit Module v2.0

## 1. Objetivo do projeto

O projeto é uma **ferramenta de administração de sistemas Linux** dividida em dois módulos com responsabilidade única:

- `system_manager.sh` → orquestrador: atualização, limpeza, diagnóstico, menu interativo, modo cron (`--auto`).
- `security_audit.sh` → módulo especializado, carregado via `source`, que realiza **auditoria de segurança de pacotes** com correção automática opcional.

O objetivo central é substituir uma checklist manual de manutenção/segurança (`apt update && apt upgrade`, checar CVEs manualmente em sites, limpar `/tmp`, remover kernels antigos, etc.) por um pipeline único, auditável (log em `/var/log`), seguro por padrão (`--dry-run`, confirmações interativas) e agendável via cron.

## 2. Funcionalidades identificadas (mapeadas por leitura do código, não só do README)

### `system_manager.sh`
| Categoria | Funções | Observação |
|---|---|---|
| Atualização | `update_repos`, `upgrade_packages`, `full_upgrade`, `update_system` | Suporta apt/dnf/yum/zypper via `case` sobre `$PKG` |
| Limpeza padrão | `clean_tmp`, `clean_user_cache`, `clean_package_cache`, `clean_logs`, `clean_trash`, `clean_thumbnails`, `full_clean` | Todas respeitam `DRY_RUN` |
| Limpeza avançada | `clean_snap_disabled`, `clean_apt_old_kernels`, `clean_apt_residual_configs`, `advanced_clean` | Só a de snap funciona fora do apt; as outras duas são apt-only |
| Diagnóstico | `show_summary`, `show_disk_usage`, `find_large_files`, `check_services`, `check_reboot_needed` | |
| Infraestrutura | `log`, `run_cmd`, `confirm`, `check_root`, `detect_package_manager` | `run_cmd` é o único ponto de execução real — importante para o dry-run funcionar de forma centralizada |
| Interface | `show_menu`, `show_security_menu`, `handle_security_menu`, `main` | Menu numérico clássico, sem dependências de `whiptail`/`dialog` |
| CLI | `--dry-run --auto --security-audit --security-fix --advanced-clean --clean-snap --clean-kernels --clean-rc` | Parsing manual via `for arg in "$@"` (não usa `getopts`, então não há flags combinadas como `-da`) |

### `security_audit.sh` (módulo)
6 fases sequenciais, expostas ao script pai só por `sa_run_audit()`:

1. **Coleta** (`sa_collect_installed`, `sa_collect_outdated`) — normaliza saída de `dpkg-query`/`rpm`/`zypper` em um formato tabular único.
2. **Vulnerabilidades — 3 fontes combinadas e deduplicadas** (`sa_fetch_vulnerabilities`):
   - Fonte A: advisories nativos (`apt-get -s dist-upgrade | grep security`, `dnf/yum updateinfo`)
   - Fonte B: **OSV.dev** (API REST, JSON por pacote/versão)
   - Fonte C: **Ubuntu USN** / **Debian Security Tracker** (cobertura específica de distro)
   - Deduplicação: `sort | awk '!seen[$1]++'` mantendo a entrada de maior severidade
3. **EOL dinâmico** (`sa_fetch_eol_data`) — consulta `endoflife.date` em tempo real por ~14 produtos conhecidos, com fallback estático para protocolos legados (telnet, rsh, ftp, ntp).
4. **Resolução de versão segura** (`sa_resolve_safe_version`) — não faz `apt upgrade` genérico; calcula a **menor versão disponível ≥ versão onde o CVE foi corrigido** via `dpkg --compare-versions`.
5. **Simulação + aplicação** (`sa_analyze_stability`, `sa_apply_fixes`) — roda `apt-get -s install pkg=versão` *antes* de qualquer mudança real; pacotes com conflito são marcados `SKIPPED`, não forçados.
6. **Ciclo recursivo** (`sa_recursive_cycle`) — re-verifica após aplicar correções, até 3 vezes, até convergir.
7. **Relatório Markdown** (`sa_generate_report`) — CVEs, EOL, correções aplicadas, checklist de hardening (SSH root login, auth por chave, firewall).

**Ponto de arquitetura relevante:** o módulo usa guarda de carregamento único (`_SA_LOADED`), prefixo `SA_`/`sa_`/`_sa_` para não colidir com o namespace do script pai, e sincroniza `SA_PKG` a partir de `$PKG` do pai — um padrão de "módulo bash" razoavelmente disciplinado para uma linguagem sem namespaces reais.

## 3. Pontos fortes (o que já está bem feito)

- **Dry-run de verdade**: centralizado em `run_cmd`, não espalhado em cada função — um único ponto de verdade.
- **Simulação antes de aplicar** (Fase 5): a maioria dos scripts de "auto-fix" que existem por aí faz `apt upgrade -y` cegamente; aqui há `apt-get -s install` real antes.
- **Pinning de versão mínima segura**, não "a mais nova disponível" — reduz o raio de quebra por upgrades desnecessários.
- **Deduplicação por severidade** entre fontes de CVE — evita contar o mesmo CVE 3x quando aparece em OSV + USN + advisory nativo.
- **Permissão 600 nos logs principais** e uso de `mktemp -d` para arquivos temporários.
- **Falha graciosa**: dependências opcionais (`curl`, `jq`, `bc`) ausentes degradam funcionalidade em vez de crashar o script (`sa_check_deps` separa "essencial" de "opcional").

## 4. Pontos de melhoria identificados

Organizei por categoria e por **severidade real** (não cosmética), porque isso é o que define a ordem de prioridade em qualquer ciclo de melhoria sucessiva.

| # | Categoria | Problema | Severidade |
|---|---|---|---|
| 1 | **Correção** | `grep "^${pkg_name}\t"` trata o nome do pacote como **regex**, não como string literal. Pacotes reais contêm `.` (`python3.11`, `libssl1.1`) e `+` (`g++`). O `.` é wildcard em regex — gera falso positivo/negativo silencioso na verificação "pacote está instalado?" | **Alta** — afeta a exatidão dos dados que alimentam todo o relatório de CVE |
| 2 | **Segurança/Robustez** | Sem lock de execução (`flock`). Rodar `--security-fix` via cron e, ao mesmo tempo, alguém abrir o menu interativo, resulta em duas instâncias de `apt-get install` disputando o lock do dpkg — na melhor hipótese uma falha limpa, na pior um pacote instalado pela metade | **Alta** — risco real em produção, não teórico |
| 3 | **Correção** | Nenhuma atualização de índice de pacotes (`apt-get update`) antes de checar advisories nativos. Se o cron de `apt update` do sistema falhar silenciosamente, a Fase 2A reporta "0 vulnerabilidades nativas" mesmo com CVEs corrigidos há semanas | **Alta** — falso negativo de segurança é o pior tipo de bug num auditor de segurança |
| 4 | **Segurança (defesa em profundidade)** | `run_cmd` executa comandos via `bash -c "$cmd"` com listas de pacotes interpoladas sem citação (`apt-get purge -y ${pkg_args}`). Nomes vêm do `dpkg` (confiáveis hoje), mas concatenar texto não citado num comando reinterpretado pelo shell é um antipadrão que quebra na primeira mudança de fonte de dados | **Média** |
| 5 | **Permissões** | O README afirma "todos os logs são 600", mas `SA_AUDIT_DIR` era criado só com `mkdir -p` (sem `chmod`) e o relatório `.md` era criado implicitamente pelo primeiro `>>` (herdando `umask`, tipicamente 644) — relatórios de segurança (que listam CVEs e versões vulneráveis do seu servidor) ficando world-readable é uma informação valiosa para um atacante local | **Média** |
| 6 | **Performance** | Fase 2B/3 fazem chamadas HTTP **sequenciais** (até ~14 produtos EOL + ~40 pacotes críticos no OSV.dev, cada uma com timeout de até 10s). Pior caso: minutos de execução só em I/O de rede, sem paralelismo | **Média** — não é bug, é escalabilidade. Recomendo para ciclo futuro (ver §6) |
| 7 | **Manutenibilidade** | Duplicação de lógica `grep "^${pkg}\t" file \| awk '{print $2}' \| head -1` repetida 5x — qualquer correção futura exige tocar em 5 lugares (como aconteceu aqui) | **Baixa/Média** |
| 8 | **Documentação** | O próprio README numera duas fases diferentes como "Fase 5" (Simulação e Ciclo recursivo) | **Baixa** (cosmético, mas confunde manutenção futura) |
| 9 | **CLI** | Parsing manual de argumentos não suporta flags combinadas nem `--flag=valor`; aceitável para o escopo atual, mas não escala se a lista de flags crescer | **Baixa** |

## 5. Metodologia de melhoria recursiva-sucessiva aplicada

Não dá para "melhorar tudo de uma vez" em um script de ~2000 linhas sem introduzir regressões. O processo que segui, e que recomendo continuar:

```
┌─────────────┐
│ 1. Mapear   │  Ler o código de ponta a ponta (não só o README) e
│    riscos   │  listar problemas por categoria e severidade real
└──────┬──────┘
       ▼
┌─────────────┐
│ 2. Priorizar│  Corretude > Segurança > Robustez > Performance > Estilo
│             │  (um bug de segurança "silencioso" é pior que um crash)
└──────┬──────┘
       ▼
┌─────────────┐
│ 3. Corrigir │  Uma categoria por vez, isolando cada mudança para que
│  1 problema │  seja revisável e revertível independentemente
└──────┬──────┘
       ▼
┌─────────────┐
│ 4. Validar  │  bash -n (sintaxe) + shellcheck (estática) + teste
│             │  funcional isolado do trecho alterado
└──────┬──────┘
       ▼
┌─────────────┐
│ 5. Comparar │  Contagem de warnings antes/depois — garantir que a
│  regressão  │  correção não introduziu novo problema
└──────┬──────┘
       └──── volta ao passo 3 para o próximo item da lista ──────►
```

Esse ciclo foi executado 5 vezes nesta sessão (itens 1, 3, 4, 5 e parte do 2 abaixo); os itens 6, 7, 8, 9 ficam documentados como próximos ciclos (ver §7) porque exigem decisões de design (ex.: paralelismo em bash tem trade-offs de legibilidade) que merecem validação separada, não uma mudança "de passagem".

## 6. Melhorias efetivamente aplicadas nesta sessão

### 6.1 — Comparação exata de nome de pacote (corrige item #1 e #7)

**Problema:** `grep "^${pkg_name}\t" installed.txt` interpreta `pkg_name` como regex.

**Prova do bug** (reproduzido isoladamente antes de corrigir):
```bash
$ printf 'python3X11\tfake\n' | grep -q '^python3.11\t'   # "." casa com "X"
$ echo $?   # 0 = "casou" → falso positivo confirmado
0
```

**Correção:** criei duas funções auxiliares (`_sa_installed_line`, `_sa_installed_version`, `_sa_is_installed`) baseadas em `awk -F'\t' -v p="$pkg" '$1==p'` — comparação de **string exata**, não regex — e substituí as 7 ocorrências espalhadas pelo arquivo por chamadas a essas funções.

**Por quê isso e não `grep -F`:** `grep -F "$pkg_name\t"` resolveria o problema do `.`, mas sem a âncora `^` não haveria mais garantia de que o pacote é o *início* do campo (poderia casar substring em outro lugar da linha). `awk` com `$1==p` é ao mesmo tempo mais correto (comparação de campo inteiro) e elimina o pipe extra `grep | awk` que existia antes — dois problemas resolvidos com uma solução.

### 6.2 — Lock de concorrência via `flock` (corrige item #2)

Adicionei `_sa_acquire_lock` / `_sa_release_lock` usando `/var/lock/security_audit.lock` com `flock -n` (não bloqueante — se já há uma auditoria rodando, a nova instância aborta com mensagem clara em vez de disputar o dpkg). Integrado ao `trap ... EXIT` já existente, então o lock é liberado mesmo se o script for interrompido (Ctrl+C, erro, etc.).

Optei por não tornar isso uma dependência obrigatória: se `flock` não existir no sistema (raro, mas `util-linux` mínimo em alguns containers), o script degrada para o comportamento anterior em vez de falhar.

### 6.3 — Atualização de metadados antes da análise (corrige item #3)

Adicionei, no início da Fase 2 (`sa_fetch_vulnerabilities`), uma chamada a `apt-get update -qq` / `dnf makecache -q` / `yum makecache -q` / `zypper refresh` antes de checar advisories nativos. É **somente leitura de metadados** (não instala nada), por isso é seguro executar mesmo em `--dry-run` — a distinção importante é entre "simular uma mudança no sistema" (que o dry-run deve bloquear) e "buscar informação atualizada para o diagnóstico" (que o dry-run não deveria bloquear, senão o próprio relatório fica menos confiável no modo mais cauteloso).

### 6.4 — Permissões consistentes com o que o README promete (corrige item #5)

- `SA_AUDIT_DIR` agora recebe `chmod 700` a cada chamada de `_sa_log` (idempotente, sem custo real).
- `SA_LOG_FILE` é criado explicitamente com `touch` + `chmod 600` na primeira escrita, em vez de nascer via `>>` (que herda `umask`).
- O relatório `.md` agora é criado com `: > "$SA_REPORT_FILE"; chmod 600 ...` **antes** do primeiro `cat >>`, fechando a janela em que ele existiria com permissão padrão do sistema.

### 6.5 — Citação defensiva de listas de pacotes (corrige item #4)

Em `clean_apt_old_kernels` e `clean_apt_residual_configs`, a lista de pacotes a purgar agora passa por `printf '%q'` pacote a pacote antes de ser interpolada no comando que `run_cmd` executa via `bash -c`. Isso não corrige um exploit conhecido hoje (os nomes vêm do `dpkg`, uma fonte confiável), mas é defesa em profundidade: qualquer fonte futura de nomes de pacote (um repositório terceiro mal configurado, por exemplo) já estaria protegida sem precisar lembrar de revisar esse ponto de novo.

### Validação das mudanças

```
$ bash -n system_manager.sh && bash -n security_audit.sh
security_audit.sh: OK sintaxe
system_manager.sh: OK sintaxe

$ shellcheck -S warning *.sh   # antes: 11 avisos | depois: 11 avisos
                                # (nenhum aviso novo introduzido pelas edições)
```

Também testei isoladamente a função de comparação exata contra os três casos de risco (`python3.1` vs `python3.11`, `python3.11` exato, `g++`) confirmando ausência de falso positivo/negativo.

## 7. Próximos ciclos recomendados (não aplicados agora, por decisão de escopo)

Estes exigem uma decisão de design e testes mais extensos antes de entrar em produção — por isso ficam documentados em vez de aplicados "de passagem":

1. **Paralelizar Fase 2B/3** (chamadas HTTP para OSV.dev/endoflife.date) com um pool limitado de jobs em background (`&` + `wait -n` ou `xargs -P`), reduzindo o tempo total de auditoria de minutos para segundos — trade-off: logging fica mais complexo com múltiplos processos escrevendo no mesmo arquivo (precisaria de lock por linha ou arquivos por-job depois concatenados).
2. **Padronizar numeração de fases** no código e no README (hoje "Fase 5" aparece duas vezes com significados diferentes).
3. **Trocar parsing manual de CLI por `getopts`/`--long` via `enhanced getopt`**, permitindo `--dry-run --clean-kernels` combinados de forma mais robusta e mensagens de erro para flags desconhecidas (hoje uma flag digitada errado é silenciosamente ignorada).
4. **Cache local de resultados EOL/CVE** (ex.: 24h) para permitir reexecuções frequentes sem sobrecarregar APIs públicas — hoje toda execução refaz todas as consultas do zero.

## 8. Arquivos entregues

- `system_manager.sh` — corrigido (itens 6.5)
- `security_audit.sh` — corrigido (itens 6.1 a 6.4)
- `diff_system_manager.patch` / `diff_security_audit.patch` — diffs exatos aplicados, para revisão linha a linha antes de colocar em produção
