#!/usr/bin/env bash

# ============================================================
# Linux System Manager - Atualização + Limpeza + Diagnóstico
# Seguro, interativo, com dry-run, modo auto e logs
# Compatível: Debian, Ubuntu, CentOS, Fedora
# ============================================================

set -euo pipefail

LOG_FILE="/var/log/system_manager.log"
DRY_RUN=false
AUTO_MODE=false
PKG="unknown"

# ---------- Cores ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- Funções utilitárias ----------

log() {
    local msg="$1"
    echo -e "$msg"
    # Salva no log sem códigos de escape ANSI
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

detect_package_manager() {
    if command -v apt >/dev/null 2>&1; then
        PKG="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG="yum"
    else
        log "${YELLOW}[AVISO]${NC} Gerenciador de pacotes não detectado. Funções de pacote desabilitadas."
    fi
}

# ---------- Diagnóstico ----------

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

# ---------- Atualização ----------

update_repos() {
    log "\n${CYAN}🔄 Atualizando repositórios...${NC}"
    case "$PKG" in
        apt) run_cmd "apt update -y" ;;
        dnf) run_cmd "dnf check-update || true" ;;
        yum) run_cmd "yum check-update || true" ;;
        *) log "${YELLOW}[SKIP]${NC} Gerenciador desconhecido." ;;
    esac
}

upgrade_packages() {
    log "\n${CYAN}⬆️  Atualizando pacotes instalados...${NC}"
    case "$PKG" in
        apt) run_cmd "apt upgrade -y" ;;
        dnf) run_cmd "dnf upgrade -y" ;;
        yum) run_cmd "yum update -y" ;;
        *) log "${YELLOW}[SKIP]${NC} Gerenciador desconhecido." ;;
    esac
}

full_upgrade() {
    log "\n${CYAN}⬆️  Realizando upgrade completo do sistema...${NC}"
    case "$PKG" in
        apt) run_cmd "apt full-upgrade -y" ;;
        dnf) run_cmd "dnf distro-sync -y" ;;
        yum) run_cmd "yum update -y" ;;
        *) log "${YELLOW}[SKIP]${NC} Gerenciador desconhecido." ;;
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

# ---------- Limpeza ----------

clean_tmp() {
    log "\n${CYAN}🧹 Limpando /tmp (arquivos não acessados há +2 dias)...${NC}"
    run_cmd "find /tmp -mindepth 1 -atime +2 -delete 2>/dev/null || true"
}

clean_user_cache() {
    log "\n${CYAN}🧹 Limpando cache de usuários...${NC}"
    run_cmd "find /home -mindepth 3 -maxdepth 3 -path '*/.cache/*' -not -path '*/.cache/thumbnails*' -delete 2>/dev/null || true"
}

clean_package_cache() {
    log "\n${CYAN}📦 Limpando cache e pacotes orphãos...${NC}"
    case "$PKG" in
        apt)
            run_cmd "apt autoremove -y"
            run_cmd "apt clean"
            ;;
        dnf)
            run_cmd "dnf autoremove -y"
            run_cmd "dnf clean all"
            ;;
        yum)
            run_cmd "yum clean all"
            ;;
        *) log "${YELLOW}[SKIP]${NC} Gerenciador desconhecido." ;;
    esac
}

clean_logs() {
    log "\n${CYAN}📜 Limpando logs do journal (>7 dias)...${NC}"
    run_cmd "journalctl --vacuum-time=7d"
    # Remove logs rotativos antigos se existirem
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

# ---------- Manutenção completa ----------

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

# ---------- Histórico ----------

view_log() {
    if [ ! -s "$LOG_FILE" ]; then
        echo -e "${YELLOW}Nenhuma operação registrada ainda.${NC}"
        return
    fi
    echo -e "\n${BOLD}${BLUE}📋 Histórico de operações:${NC} $LOG_FILE\n"
    # Usa less se disponível, senão exibe direto
    if command -v less >/dev/null 2>&1; then
        less +G "$LOG_FILE"
    else
        cat "$LOG_FILE"
    fi
}

# ---------- Menu ----------

show_menu() {
    echo -e "
${BOLD}${BLUE}╔══════════════════════════════════╗
║     Linux System Manager v2.0    ║
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

  0) Sair
${BLUE}════════════════════════════════════${NC}"
}

# ---------- Main ----------

main() {
    check_root
    detect_package_manager

    # Garante que o arquivo de log existe e tem permissões corretas
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    log "===== INÍCIO: $(date '+%Y-%m-%d %H:%M:%S') ====="
    [ "$DRY_RUN" = true ] && log "${YELLOW}[MODO DRY-RUN ATIVADO - nenhuma alteração será feita]${NC}"
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
            0)  break ;;
            *)  echo -e "${RED}Opção inválida.${NC}" ;;
        esac
    done

    show_disk_usage
    log "===== FIM: $(date '+%Y-%m-%d %H:%M:%S') ====="
}

# ---------- Ajuda ----------

usage() {
    echo "Uso: $0 [--dry-run] [--auto]"
    echo ""
    echo "  --dry-run   Simula as operações sem executar nada"
    echo "  --auto      Executa manutenção completa sem interação"
    echo ""
    echo "Sem argumentos: abre o menu interativo"
    exit 0
}

# ---------- Argumentos ----------

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --auto)    AUTO_MODE=true ;;
        --help|-h) usage ;;
    esac
done

main
