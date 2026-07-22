#!/usr/bin/env bash

# ============================================================
# Linux System Manager v2.1
# Atualização + Limpeza + Diagnóstico
# Seguro, interativo, dry-run, modo auto, logs
# Compatível: Debian, Ubuntu, CentOS, Fedora, RHEL, openSUSE
# Módulo de segurança: security_audit.sh (carregado automaticamente)
# ============================================================

set -euo pipefail

# ================================================================
# CARREGAR MÓDULO DE AUDITORIA DE SEGURANÇA
# ================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! source "${SCRIPT_DIR}/security_audit.sh" 2>/dev/null; then
    echo -e "\033[0;31m[ERRO]\033[0m security_audit.sh não encontrado em ${SCRIPT_DIR}" >&2
    exit 1
fi

# ================================================================
# CONFIGURAÇÃO GLOBAL
# ================================================================

LOG_FILE="/var/log/system_manager.log"

DRY_RUN=false
AUTO_MODE=false
PKG="unknown"

# ================================================================
# CORES
# ================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ================================================================
# UTILITÁRIOS GERAIS
# ================================================================

log() {
    local msg="$1"
    echo -e "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $(printf '%s' "$msg" | sed 's/\x1B\[[0-9;]*m//g')" >> "$LOG_FILE"
}

run_cmd() {
    local cmd="$*"
    if [ "$DRY_RUN" = true ]; then
        log "${YELLOW}[DRY-RUN]${NC} $cmd"
    else
        if ! bash -c "$cmd" >> "$LOG_FILE" 2>&1; then
            log "${RED}[ERRO]${NC} Falhou: $cmd"
            return 1
        fi
    fi
}

confirm() {
    [ "$AUTO_MODE" = true ] && return 0
    local resp
    read -rp "$(echo -e "${YELLOW}$1${NC} [y/N]: ")" resp
    [[ "$resp" =~ ^[Yy]$ ]]
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERRO]${NC} Execute como root ou com sudo."
        exit 1
    fi
}

# ================================================================
# DETECÇÃO DE GERENCIADOR DE PACOTES
# ================================================================

detect_package_manager() {
    if command -v apt >/dev/null 2>&1; then
        PKG="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG="yum"
    elif command -v zypper >/dev/null 2>&1; then
        PKG="zypper"
    else
        log "${YELLOW}[AVISO]${NC} Gerenciador de pacotes não detectado."
    fi
}

# ================================================================
# DIAGNÓSTICO DO SISTEMA
# ================================================================

show_disk_usage() {
    log "\n${BOLD}${BLUE}📊 Uso de disco:${NC}"
    df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs 2>/dev/null || df -h /
}

show_summary() {
    local os kernel uptime_info ram
    os=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "Desconhecido")
    kernel=$(uname -r)
    uptime_info=$(uptime -p 2>/dev/null || uptime)
    ram=$(free -h | awk '/^Mem:/{printf "%s / %s (%.0f%% usado)", $3, $2, ($3/$2)*100}')

    log "\n${BOLD}${BLUE}📋 Resumo do sistema:${NC}"
    log "  ${BOLD}OS:${NC}      $os"
    log "  ${BOLD}Kernel:${NC}  $kernel"
    log "  ${BOLD}Uptime:${NC}  $uptime_info"
    log "  ${BOLD}RAM:${NC}     $ram"
    log "  ${BOLD}PKG:${NC}     $PKG"
    show_disk_usage
}

find_large_files() {
    log "\n${BLUE}🔍 Arquivos grandes (>500MB):${NC}"
    find / -xdev -type f -size +500M -exec ls -lh {} \; 2>/dev/null \
        | awk '{print $5 "\t" $9}' | sort -rh || true
}

check_services() {
    log "\n${BLUE}⚙️  Serviços habilitados (top 25):${NC}"
    systemctl list-unit-files --type=service --state=enabled 2>/dev/null | head -n 25 || true
}

check_reboot_needed() {
    if [ -f /var/run/reboot-required ]; then
        log "\n${YELLOW}⚠️  Reinicialização necessária para aplicar atualizações.${NC}"
        if confirm "Reiniciar agora?"; then
            reboot
        fi
    fi
}

# ================================================================
# ATUALIZAÇÃO
# ================================================================

update_repos() {
    log "\n${CYAN}🔄 Atualizando repositórios...${NC}"
    case "$PKG" in
        apt)    run_cmd "apt update -y" ;;
        dnf)    run_cmd "dnf check-update || true" ;;
        yum)    run_cmd "yum check-update || true" ;;
        zypper) run_cmd "zypper refresh" ;;
        *)      log "${YELLOW}[SKIP]${NC} Gerenciador desconhecido." ;;
    esac
}

upgrade_packages() {
    log "\n${CYAN}⬆️  Atualizando pacotes instalados...${NC}"
    case "$PKG" in
        apt)    run_cmd "apt upgrade -y" ;;
        dnf)    run_cmd "dnf upgrade -y" ;;
        yum)    run_cmd "yum update -y" ;;
        zypper) run_cmd "zypper update -y" ;;
        *)      log "${YELLOW}[SKIP]${NC} Gerenciador desconhecido." ;;
    esac
}

full_upgrade() {
    log "\n${CYAN}⬆️  Realizando upgrade completo do sistema...${NC}"
    case "$PKG" in
        apt)    run_cmd "apt full-upgrade -y" ;;
        dnf)    run_cmd "dnf distro-sync -y" ;;
        yum)    run_cmd "yum update -y" ;;
        zypper) run_cmd "zypper dist-upgrade -y" ;;
        *)      log "${YELLOW}[SKIP]${NC} Gerenciador desconhecido." ;;
    esac
}

update_system() {
    confirm "Atualizar sistema completo (repos + pacotes + full-upgrade)?" || return 0
    local disk_before
    disk_before=$(df -h / | awk 'NR==2{print $4}')
    update_repos
    upgrade_packages
    full_upgrade
    local disk_after
    disk_after=$(df -h / | awk 'NR==2{print $4}')
    log "\n${GREEN}✅ Sistema atualizado! Espaço livre: ${disk_before} → ${disk_after}${NC}"
    check_reboot_needed
}

# ================================================================
# LIMPEZA
# ================================================================

clean_tmp() {
    log "\n${CYAN}🧹 Limpando /tmp (arquivos não acessados há +2 dias)...${NC}"
    run_cmd "find /tmp -mindepth 1 -atime +2 -delete 2>/dev/null || true"
}

clean_user_cache() {
    log "\n${CYAN}🧹 Limpando cache de usuários...${NC}"
    run_cmd "find /home -mindepth 3 -maxdepth 3 -path '*/.cache/*' -not -path '*/.cache/thumbnails*' -delete 2>/dev/null || true"
}

clean_package_cache() {
    log "\n${CYAN}📦 Limpando cache e pacotes orfãos...${NC}"
    case "$PKG" in
        apt)
            run_cmd "apt autoremove -y"
            run_cmd "apt clean"
            run_cmd "apt autoclean"
            ;;
        dnf)
            run_cmd "dnf autoremove -y"
            run_cmd "dnf clean all"
            ;;
        yum)
            run_cmd "yum clean all"
            ;;
        zypper)
            run_cmd "zypper clean --all"
            ;;
        *) log "${YELLOW}[SKIP]${NC} Gerenciador desconhecido." ;;
    esac
}

clean_logs() {
    log "\n${CYAN}📜 Limpando logs do journal (>7 dias)...${NC}"
    run_cmd "journalctl --vacuum-time=7d"
    run_cmd "find /var/log -type f -name '*.gz' -mtime +30 -delete 2>/dev/null || true"
    run_cmd "find /var/log -type f -name '*.old' -mtime +30 -delete 2>/dev/null || true"
}

clean_trash() {
    log "\n${CYAN}🗑️  Esvaziando lixeira...${NC}"
    run_cmd "find /home -mindepth 4 -path '*/.local/share/Trash/*' -delete 2>/dev/null || true"
    run_cmd "find /root/.local/share/Trash -mindepth 1 -delete 2>/dev/null || true"
}

clean_thumbnails() {
    log "\n${CYAN}🖼️  Limpando thumbnails...${NC}"
    run_cmd "find /home -mindepth 4 -path '*/.cache/thumbnails/*' -delete 2>/dev/null || true"
}

# ================================================================
# LIMPEZA AVANÇADA (Snap desabilitados / Kernels antigos / RC)
# ================================================================

clean_snap_disabled() {
    if ! command -v snap >/dev/null 2>&1; then
        log "${YELLOW}[SKIP]${NC} snap não está instalado neste sistema."
        return 0
    fi

    log "\n${CYAN}📦 Verificando revisões 'disabled' do snap...${NC}"

    local entries
    entries=$(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}') || true

    if [ -z "$entries" ]; then
        log "${GREEN}✅ Nenhuma revisão disabled encontrada.${NC}"
        return 0
    fi

    log "${BLUE}As seguintes revisões serão removidas:${NC}"
    while read -r snapname revision; do
        [ -z "$snapname" ] && continue
        log "  - ${snapname} (revision ${revision})"
    done <<< "$entries"

    if [ "$DRY_RUN" != true ]; then
        confirm "Confirmar remoção das revisões acima?" || { log "${YELLOW}Cancelado pelo usuário.${NC}"; return 0; }
    fi

    local count=0
    while read -r snapname revision; do
        [ -z "$snapname" ] && continue
        if [ "$DRY_RUN" = true ]; then
            log "${YELLOW}[DRY-RUN]${NC} snap remove ${snapname} --revision=${revision}"
        else
            if run_cmd "snap remove '${snapname}' --revision='${revision}'"; then
                count=$((count + 1))
            fi
        fi
    done <<< "$entries"

    if [ "$DRY_RUN" = true ]; then
        log "${GREEN}✅ Simulação concluída (nenhuma revisão foi removida).${NC}"
    else
        log "${GREEN}✅ ${count} revisão(ões) snap removida(s).${NC}"
    fi
}

clean_apt_old_kernels() {
    if [ "$PKG" != "apt" ]; then
        log "${YELLOW}[SKIP]${NC} Remoção de kernels antigos disponível apenas para apt (Debian/Ubuntu)."
        return 0
    fi

    log "\n${CYAN}🐧 Verificando kernels antigos instalados...${NC}"

    local current_kernel current_pkg
    current_kernel=$(uname -r)
    current_pkg="linux-image-${current_kernel}"

    local installed_kernels
    installed_kernels=$(dpkg-query -W -f='${Package}\n' 'linux-image-*' 2>/dev/null | grep -E '^linux-image-[0-9]' || true)

    if [ -z "$installed_kernels" ]; then
        log "${GREEN}✅ Nenhum pacote de kernel encontrado para análise.${NC}"
        return 0
    fi

    # Mantém o kernel em execução + o mais recente instalado; remove os demais.
    local latest_kernel
    latest_kernel=$(echo "$installed_kernels" | sed 's/^linux-image-//' | sort -V | tail -n1)
    local latest_pkg="linux-image-${latest_kernel}"

    local to_remove
    to_remove=$(echo "$installed_kernels" | grep -v -F -x "$current_pkg" | grep -v -F -x "$latest_pkg" || true)

    if [ -z "$to_remove" ]; then
        log "${GREEN}✅ Nenhum kernel antigo elegível para remoção (apenas atual/mais recente instalados).${NC}"
        return 0
    fi

    # Inclui os pacotes -headers correspondentes, se existirem.
    local full_list="$to_remove"
    while read -r pkg; do
        [ -z "$pkg" ] && continue
        local ver="${pkg#linux-image-}"
        local hdr="linux-headers-${ver}"
        dpkg-query -W -f='${Package}\n' "$hdr" >/dev/null 2>&1 && full_list="${full_list}"$'\n'"${hdr}"
    done <<< "$to_remove"

    log "${BLUE}Kernel em execução (mantido): ${current_kernel}${NC}"
    log "${BLUE}Kernel mais recente instalado (mantido): ${latest_kernel}${NC}"
    log "${BLUE}Pacotes que serão removidos:${NC}"
    while read -r pkg; do
        [ -z "$pkg" ] && continue
        log "  - ${pkg}"
    done <<< "$full_list"

    if [ "$DRY_RUN" != true ]; then
        confirm "Confirmar remoção dos kernels antigos acima?" || { log "${YELLOW}Cancelado pelo usuário.${NC}"; return 0; }
    fi

    # MELHORIA: cada nome de pacote é citado individualmente (printf %q)
    # antes de compor o comando que o run_cmd executa via `bash -c`.
    # Isso é defesa em profundidade: os nomes vêm do dpkg (confiáveis), mas
    # concatenar texto não citado em um comando que será reinterpretado
    # pelo shell é um antipadrão — qualquer futura fonte de dados (ex.: um
    # nome de pacote de um repositório de terceiros mal formado) poderia
    # injetar metacaracteres de shell.
    local pkg_args=""
    while read -r pkg; do
        [ -z "$pkg" ] && continue
        pkg_args+=" $(printf '%q' "$pkg")"
    done <<< "$full_list"

    if [ "$DRY_RUN" = true ]; then
        log "${YELLOW}[DRY-RUN]${NC} apt-get purge -y ${pkg_args}"
    else
        run_cmd "apt-get purge -y ${pkg_args}"
        run_cmd "apt-get autoremove -y"
        log "${GREEN}✅ Kernels antigos removidos.${NC}"
    fi
}

clean_apt_residual_configs() {
    if [ "$PKG" != "apt" ]; then
        log "${YELLOW}[SKIP]${NC} Limpeza de configs residuais disponível apenas para apt (Debian/Ubuntu)."
        return 0
    fi

    log "\n${CYAN}🗑️  Verificando pacotes com configuração residual (estado 'rc')...${NC}"

    local rc_pkgs
    rc_pkgs=$(dpkg -l | awk '/^rc/{print $2}')

    if [ -z "$rc_pkgs" ]; then
        log "${GREEN}✅ Nenhum pacote com configuração residual encontrado.${NC}"
        return 0
    fi

    log "${BLUE}Pacotes com config residual que serão purgados:${NC}"
    for pkg in $rc_pkgs; do
        log "  - ${pkg}"
    done

    if [ "$DRY_RUN" != true ]; then
        confirm "Confirmar purge dos pacotes acima?" || { log "${YELLOW}Cancelado pelo usuário.${NC}"; return 0; }
    fi

    # MELHORIA: mesma citação individual aplicada em clean_apt_old_kernels
    local pkg_args=""
    for pkg in $rc_pkgs; do
        pkg_args+=" $(printf '%q' "$pkg")"
    done

    if [ "$DRY_RUN" = true ]; then
        log "${YELLOW}[DRY-RUN]${NC} apt-get purge -y ${pkg_args}"
    else
        run_cmd "apt-get purge -y ${pkg_args}"
        log "${GREEN}✅ Configurações residuais removidas.${NC}"
    fi
}

advanced_clean() {
    confirm "Executar limpeza avançada (snap disabled + kernels antigos + configs residuais)?" || return 0
    local disk_before
    disk_before=$(df -h / | awk 'NR==2{print $4}')
    clean_snap_disabled
    clean_apt_old_kernels
    clean_apt_residual_configs
    local disk_after
    disk_after=$(df -h / | awk 'NR==2{print $4}')
    log "\n${GREEN}✅ Limpeza avançada concluída! Espaço livre: ${disk_before} → ${disk_after}${NC}"
}

full_clean() {
    confirm "Executar limpeza completa?" || return 0
    local disk_before
    disk_before=$(df -h / | awk 'NR==2{print $4}')
    clean_tmp
    clean_user_cache
    clean_package_cache
    clean_logs
    clean_trash
    clean_thumbnails
    local disk_after
    disk_after=$(df -h / | awk 'NR==2{print $4}')
    log "\n${GREEN}✅ Limpeza concluída! Espaço livre: ${disk_before} → ${disk_after}${NC}"
}

# ================================================================
# MANUTENÇÃO COMPLETA
# ================================================================

full_maintenance() {
    confirm "Executar manutenção completa (atualização + limpeza)?" || return 0
    log "\n${BOLD}${BLUE}🚀 Iniciando manutenção completa...${NC}"
    local disk_before
    disk_before=$(df -h / | awk 'NR==2{print $4}')
    update_repos
    upgrade_packages
    full_upgrade
    clean_tmp
    clean_user_cache
    clean_package_cache
    clean_logs
    clean_trash
    clean_thumbnails
    local disk_after
    disk_after=$(df -h / | awk 'NR==2{print $4}')
    log "\n${GREEN}${BOLD}✅ Manutenção completa concluída!${NC}"
    log "   Espaço livre: ${disk_before} → ${disk_after}"
    check_reboot_needed
}

# ================================================================
# HISTÓRICO
# ================================================================

view_log() {
    if [ ! -s "$LOG_FILE" ]; then
        echo -e "${YELLOW}Nenhuma operação registrada ainda.${NC}"
        return
    fi
    echo -e "\n${BOLD}${BLUE}📋 Histórico de operações:${NC} $LOG_FILE\n"
    if command -v less >/dev/null 2>&1; then
        less +G "$LOG_FILE"
    else
        cat "$LOG_FILE"
    fi
}

run_security_audit() {
    sa_run_audit "${1:-false}" "${2:-false}"
}

# ================================================================
# MENUS
# ================================================================

show_security_menu() {
    echo -e "
${BOLD}${MAGENTA}╔══════════════════════════════════════╗
║   🔐 Auditoria de Segurança v2.0     ║
╚══════════════════════════════════════╝${NC}
 ${BOLD}[ Modos de Auditoria ]${NC}
  1) Auditoria completa (somente relatório)
  2) Auditoria + aplicar correções de segurança
  3) Auditoria em modo DRY-RUN (simulação)

 ${BOLD}[ Relatórios ]${NC}
  4) Ver último relatório gerado
  5) Listar todos os relatórios salvos

  0) Voltar ao menu principal
${MAGENTA}══════════════════════════════════════${NC}"
}

handle_security_menu() {
    while true; do
        show_security_menu
        read -rp "$(echo -e "${BOLD}Escolha:${NC} ")" sec_opt
        case $sec_opt in
            1) sa_run_audit false false ;;
            2) confirm "Aplicar correções de segurança?" && sa_run_audit false true || true ;;
            3) sa_run_audit true  false ;;
            4) sa_view_last_report ;;
            5) sa_list_reports ;;
            0) break ;;
            *) echo -e "${RED}Opção inválida.${NC}" ;;
        esac
    done
}

show_menu() {
    echo -e "
${BOLD}${BLUE}╔══════════════════════════════════╗
║     Linux System Manager v2.1    ║
╚══════════════════════════════════╝${NC}
 ${BOLD}[ Atualização ]${NC}
  1) Atualizar sistema completo

 ${BOLD}[ Limpeza ]${NC}
  2) Limpeza completa
  3) Limpar /tmp
  4) Limpar cache de pacotes + orphãos
  5) Limpar logs antigos
  6) Limpar lixeira e thumbnails

 ${BOLD}[ Diagnóstico ]${NC}
  7) Ver arquivos grandes (>500MB)
  8) Ver serviços habilitados
  9) Resumo do sistema

 ${BOLD}[ Manutenção ]${NC}
 10) Manutenção completa (update + clean)

 ${BOLD}[ Histórico ]${NC}
 11) Ver log de operações

 ${BOLD}${MAGENTA}[ 🔐 Segurança ]${NC}
 12) Auditoria de segurança de pacotes
 13) Auditoria rápida (DRY-RUN)

 ${BOLD}[ 🧹 Limpeza Avançada ]${NC}
 14) Remover revisões snap desabilitadas
 15) Remover kernels antigos (apt)
 16) Remover pacotes com config residual (apt)
 17) Executar as 3 limpezas avançadas

  0) Sair
${BLUE}════════════════════════════════════${NC}"
}

# ================================================================
# MAIN
# ================================================================

main() {
    check_root
    detect_package_manager

    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    log "===== INÍCIO: $(date '+%Y-%m-%d %H:%M:%S') ====="
    [ "$DRY_RUN" = true ] && log "${YELLOW}[MODO DRY-RUN ATIVADO]${NC}"
    show_summary

    if [ "$AUTO_MODE" = true ]; then
        log "\n${YELLOW}⚡ Modo automático ativado.${NC}"
        full_maintenance
        log "===== FIM: $(date '+%Y-%m-%d %H:%M:%S') ====="
        return
    fi

    while true; do
        show_menu
        read -rp "$(echo -e "${BOLD}Escolha:${NC} ")" opt
        case $opt in
            1)  update_system ;;
            2)  full_clean ;;
            3)  clean_tmp ;;
            4)  clean_package_cache ;;
            5)  clean_logs ;;
            6)  clean_trash; clean_thumbnails ;;
            7)  find_large_files ;;
            8)  check_services ;;
            9)  show_summary ;;
            10) full_maintenance ;;
            11) view_log ;;
            12) handle_security_menu ;;
            13) run_security_audit true false ;;
            14) clean_snap_disabled ;;
            15) clean_apt_old_kernels ;;
            16) clean_apt_residual_configs ;;
            17) advanced_clean ;;
            0)  break ;;
            *)  echo -e "${RED}Opção inválida.${NC}" ;;
        esac
    done

    show_disk_usage
    log "===== FIM: $(date '+%Y-%m-%d %H:%M:%S') ====="
}

# ================================================================
# AJUDA
# ================================================================

usage() {
    echo "Uso: $0 [--dry-run] [--auto] [--security-audit] [--security-fix] [--advanced-clean] [--clean-snap] [--clean-kernels] [--clean-rc]"
    echo ""
    echo "  --dry-run         Simula as operações sem executar nada"
    echo "  --auto            Manutenção completa sem interação (cron-friendly)"
    echo "  --security-audit  Auditoria de segurança + relatório .md"
    echo "  --security-fix    Auditoria + aplica correções automaticamente"
    echo "  --advanced-clean  Remove revisões snap disabled + kernels antigos + configs residuais (apt)"
    echo "  --clean-snap      Remove apenas as revisões snap 'disabled'"
    echo "  --clean-kernels   Remove apenas kernels antigos (apt, mantém atual + mais recente)"
    echo "  --clean-rc        Remove apenas pacotes com config residual (apt, estado 'rc')"
    echo ""
    echo "Sem argumentos: abre o menu interativo"
    exit 0
}

# ================================================================
# ARGUMENTOS CLI
# ================================================================

SECURITY_AUDIT_MODE=false
SECURITY_FIX_MODE=false
ADVANCED_CLEAN_MODE=false
CLEAN_SNAP_MODE=false
CLEAN_KERNELS_MODE=false
CLEAN_RC_MODE=false

for arg in "$@"; do
    case $arg in
        --dry-run)         DRY_RUN=true ;;
        --auto)            AUTO_MODE=true ;;
        --security-audit)  SECURITY_AUDIT_MODE=true ;;
        --security-fix)    SECURITY_FIX_MODE=true ;;
        --advanced-clean)  ADVANCED_CLEAN_MODE=true ;;
        --clean-snap)      CLEAN_SNAP_MODE=true ;;
        --clean-kernels)   CLEAN_KERNELS_MODE=true ;;
        --clean-rc)        CLEAN_RC_MODE=true ;;
        --help|-h)         usage ;;
    esac
done

if [ "$SECURITY_AUDIT_MODE" = true ] || [ "$SECURITY_FIX_MODE" = true ]; then
    check_root
    detect_package_manager
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    if [ "$SECURITY_FIX_MODE" = true ]; then
        run_security_audit false true
    else
        run_security_audit "$DRY_RUN" false
    fi
    exit 0
fi

if [ "$ADVANCED_CLEAN_MODE" = true ] || [ "$CLEAN_SNAP_MODE" = true ] || [ "$CLEAN_KERNELS_MODE" = true ] || [ "$CLEAN_RC_MODE" = true ]; then
    check_root
    detect_package_manager
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    # Invocação explícita via CLI = consentimento; pula confirmações interativas (cron-friendly)
    AUTO_MODE=true
    [ "$ADVANCED_CLEAN_MODE" = true ] && advanced_clean
    [ "$CLEAN_SNAP_MODE" = true ] && clean_snap_disabled
    [ "$CLEAN_KERNELS_MODE" = true ] && clean_apt_old_kernels
    [ "$CLEAN_RC_MODE" = true ] && clean_apt_residual_configs
    exit 0
fi

main
