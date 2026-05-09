#!/usr/bin/env bash

# ============================================================
# security_audit.sh — Módulo de Auditoria de Segurança v2.0
# Parte do Linux System Manager
#
# Melhorias implementadas:
#   1. EOL dinâmico via endoflife.date API
#   2. Ubuntu USN + Debian Security Tracker (além do OSV.dev)
#   3. Pinning de versão segura (apt install pkg=versão)
#   4. Simulação de upgrade antes de aplicar (apt -s install)
#
# Uso standalone: sudo ./security_audit.sh [--dry-run] [--apply-fixes]
# Uso como módulo: source security_audit.sh  (expõe sa_* functions)
# ============================================================

# Não redefinir set se já foi definido pelo script pai
[[ "${_SA_LOADED:-}" == "1" ]] && return 0
_SA_LOADED=1

# ================================================================
# CONFIGURAÇÃO DO MÓDULO
# ================================================================

SA_AUDIT_DIR="/var/log/security_audit"
SA_REPORT_DATE=$(date '+%Y%m%d_%H%M%S')
SA_REPORT_FILE="${SA_AUDIT_DIR}/security_report_${SA_REPORT_DATE}.md"
SA_TMP_DIR=$(mktemp -d /tmp/sec_audit_XXXXXX)
SA_LOG_FILE="${SA_AUDIT_DIR}/audit.log"

SA_RECURSIVE_MAX=3
SA_STABILITY_THRESHOLD=5

# Contadores (prefixo SA_ para não colidir com o script pai)
SA_TOTAL=0
SA_OUTDATED=0
SA_VULNERABLE=0
SA_CRITICAL=0
SA_HIGH=0
SA_DEPRECATED=0
SA_UPDATED=0
SA_SKIPPED=0
SA_RECURSIVE_CYCLE=0

# SA_PKG é resolvido em sa_run_audit (após detect_package_manager do pai já ter rodado)
SA_PKG="unknown"
SA_DRY_RUN="${DRY_RUN:-false}"

# Cores (herda do pai ou redefine)
_R='\033[0;31m'; _G='\033[0;32m'; _Y='\033[1;33m'
_B='\033[0;34m'; _C='\033[0;36m'; _M='\033[0;35m'
_BOLD='\033[1m'; _NC='\033[0m'

# ================================================================
# UTILITÁRIOS DO MÓDULO
# ================================================================

_sa_log() {
    local level="$1" msg="$2" color="$_NC"
    case "$level" in
        INFO)  color="$_C"  ;; OK)    color="$_G"  ;;
        WARN)  color="$_Y"  ;; ERROR) color="$_R"  ;;
        AUDIT) color="$_M"  ;; STEP)  color="$_B"  ;;
    esac
    echo -e "${color}[${level}]${_NC} $msg"
    mkdir -p "$SA_AUDIT_DIR"
    printf '%s [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$level" \
        "$(printf '%s' "$msg" | sed 's/\x1B\[[0-9;]*m//g')" \
        >> "$SA_LOG_FILE"
}

_sa_progress() {
    local current="$1" total="$2" label="${3:-Processando}"
    local width=40
    local pct=$(( current * 100 / (total > 0 ? total : 1) ))
    local filled=$(( width * current / (total > 0 ? total : 1) ))
    local bar="" i
    for (( i=0; i<filled; i++ ));       do bar+="█"; done
    for (( i=filled; i<width; i++ ));   do bar+="░"; done
    printf "\r${_C}%s${_NC} [${_G}%s${_NC}] %3d%%" "$label" "$bar" "$pct"
    if [ "$current" -eq "$total" ]; then echo ""; fi
    return 0
}

# curl seguro: retorna fallback em vez de falhar
_sa_curl() {
    local fallback="${1}"; shift
    curl -s --connect-timeout 4 --max-time 10 "$@" 2>/dev/null || echo "$fallback"
}

# Limpeza do diretório temporário
_sa_cleanup() { rm -rf "$SA_TMP_DIR"; }
trap _sa_cleanup EXIT

# ================================================================
# VERIFICAÇÃO DE DEPENDÊNCIAS
# ================================================================

sa_check_deps() {
    _sa_log "STEP" "Verificando dependências..."
    local missing=() optional=()

    for cmd in awk sed grep wc sort dpkg-query apt-get; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    command -v curl >/dev/null 2>&1 || optional+=("curl  → CVE lookup e EOL dinâmico desabilitados")
    command -v jq   >/dev/null 2>&1 || optional+=("jq    → parsing JSON limitado a grep")
    command -v bc   >/dev/null 2>&1 || optional+=("bc    → comparação de CVSS score desabilitada")

    if [ "${#missing[@]}" -gt 0 ]; then
        _sa_log "ERROR" "Ferramentas essenciais ausentes: ${missing[*]}"
        return 1
    fi
    if [ "${#optional[@]}" -gt 0 ]; then
        _sa_log "WARN" "Ferramentas opcionais ausentes:"
        for o in "${optional[@]}"; do _sa_log "WARN" "  - $o"; done
    fi
    _sa_log "OK" "Dependências verificadas."
}

# ================================================================
# FASE 1 — COLETA DE DADOS
# ================================================================

sa_collect_installed() {
    local outfile="${SA_TMP_DIR}/installed.txt"
    _sa_log "STEP" "Coletando pacotes instalados via ${SA_PKG}..."

    case "$SA_PKG" in
        apt)
            dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 2>/dev/null \
                | awk '/install ok installed/{print $1"\t"$2}' > "$outfile"
            ;;
        dnf|yum)
            rpm -qa --queryformat '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null \
                | sort > "$outfile"
            ;;
        zypper)
            zypper se --installed-only -s 2>/dev/null \
                | awk '/^\|/ && !/^| S/{print $3"\t"$7}' > "$outfile"
            ;;
        *)
            _sa_log "ERROR" "Gerenciador não suportado: $SA_PKG"; return 1 ;;
    esac

    SA_TOTAL=$(wc -l < "$outfile")
    _sa_log "OK" "Pacotes instalados: ${_BOLD}${SA_TOTAL}${_NC}"
}

sa_collect_outdated() {
    local outfile="${SA_TMP_DIR}/outdated.txt"
    > "$outfile"
    _sa_log "STEP" "Verificando pacotes desatualizados..."

    case "$SA_PKG" in
        apt)
            apt list --upgradable 2>/dev/null \
                | grep -v "^Listing" \
                | awk -F'[/ ]' '{print $1"\t"$3"\t"$5}' >> "$outfile" || true
            ;;
        dnf)
            dnf check-update --quiet 2>/dev/null \
                | grep -v "^$\|^Last\|^Loaded" \
                | awk '{print $1"\t"$2"\t(atual)"}' >> "$outfile" || true
            ;;
        yum)
            yum check-update --quiet 2>/dev/null \
                | grep -v "^$\|^Loaded\|^Last" \
                | awk '{print $1"\t"$2"\t(atual)"}' >> "$outfile" || true
            ;;
    esac

    SA_OUTDATED=$(wc -l < "$outfile")
    _sa_log "OK" "Pacotes desatualizados: ${_BOLD}${SA_OUTDATED}${_NC}"
}

# ================================================================
# FASE 2A — EOL DINÂMICO via endoflife.date API
# Melhoria 1: substitui lista estática por consulta em tempo real
# ================================================================

sa_fetch_eol_data() {
    local outfile="${SA_TMP_DIR}/eol_results.txt"
    > "$outfile"

    if ! command -v curl >/dev/null 2>&1; then
        _sa_log "WARN" "curl ausente — verificação dinâmica de EOL desabilitada."
        return 0
    fi

    # Testa conectividade
    if ! _sa_curl "" "https://endoflife.date/api/all.json" | grep -q '\[' 2>/dev/null; then
        _sa_log "WARN" "Sem acesso a endoflife.date — verificação dinâmica de EOL desabilitada."
        return 0
    fi

    _sa_log "STEP" "Consultando datas de EOL via endoflife.date..."

    # Produtos para verificar e o pacote Debian/RPM associado
    # formato: "produto_endoflife:pacote_sistema:nome_amigável"
    local products=(
        "python:python3:Python"
        "python:python2:Python 2"
        "php:php:PHP"
        "nodejs:nodejs:Node.js"
        "mysql:mysql-server:MySQL"
        "mariadb:mariadb-server:MariaDB"
        "nginx:nginx:Nginx"
        "apache:apache2:Apache HTTP"
        "debian:base-files:Debian"
        "ubuntu:base-files:Ubuntu"
        "openssh:openssh-server:OpenSSH"
        "openssl:openssl:OpenSSL"
        "redis:redis-server:Redis"
        "postgresql:postgresql:PostgreSQL"
    )

    local today
    today=$(date '+%Y-%m-%d')
    local checked=0 total=${#products[@]}

    for entry in "${products[@]}"; do
        local product pkg_name friendly_name
        product=$(echo "$entry" | cut -d: -f1)
        pkg_name=$(echo "$entry" | cut -d: -f2)
        friendly_name=$(echo "$entry" | cut -d: -f3)

        checked=$(( checked + 1 ))
        _sa_progress "$checked" "$total" "Verificando EOL"

        # Verifica se o pacote está instalado
        if ! grep -q "^${pkg_name}\t" "${SA_TMP_DIR}/installed.txt" 2>/dev/null; then
            continue
        fi

        local installed_version
        installed_version=$(grep "^${pkg_name}\t" "${SA_TMP_DIR}/installed.txt" | awk '{print $2}' | head -1)

        # Busca dados de EOL para o produto
        local eol_data
        eol_data=$(_sa_curl "[]" "https://endoflife.date/api/${product}.json")

        if ! echo "$eol_data" | grep -q '"eol"'; then
            continue
        fi

        # Extrai o ciclo mais relevante para a versão instalada
        local major_version eol_date is_eol latest_version
        major_version=$(echo "$installed_version" | grep -o '^[0-9]*\.[0-9]*' | head -1)

        if command -v jq >/dev/null 2>&1; then
            # Tenta encontrar o ciclo exato; cai no mais recente se não achar
            local cycle_data
            cycle_data=$(echo "$eol_data" | jq -r \
                --arg cycle "$major_version" \
                '.[] | select(.cycle == $cycle or (.cycle | startswith($cycle)))' 2>/dev/null \
                | head -1)

            if [ -z "$cycle_data" ]; then
                cycle_data=$(echo "$eol_data" | jq -r '.[0]' 2>/dev/null)
            fi

            eol_date=$(echo "$cycle_data" | jq -r '.eol // "unknown"' 2>/dev/null || echo "unknown")
            latest_version=$(echo "$cycle_data" | jq -r '.latest // "unknown"' 2>/dev/null || echo "unknown")
            is_eol=$(echo "$cycle_data" | jq -r '.eol' 2>/dev/null || echo "unknown")

            # eol pode ser boolean true/false ou uma data string
            if [[ "$is_eol" == "true" ]] || \
               ([[ "$is_eol" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$is_eol" < "$today" ]]); then
                echo "${pkg_name}|${friendly_name}|${installed_version}|${eol_date}|${latest_version}|EOL_CONFIRMED" >> "$outfile"
                SA_DEPRECATED=$(( SA_DEPRECATED + 1 ))
            elif [[ "$eol_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                # Calcula dias até EOL
                local eol_epoch today_epoch days_left
                eol_epoch=$(date -d "$eol_date" '+%s' 2>/dev/null || echo 0)
                today_epoch=$(date '+%s')
                days_left=$(( (eol_epoch - today_epoch) / 86400 ))
                if [ "$days_left" -le 180 ]; then
                    echo "${pkg_name}|${friendly_name}|${installed_version}|${eol_date}|${latest_version}|EOL_SOON_${days_left}d" >> "$outfile"
                fi
            fi
        else
            # Fallback sem jq: grep básico
            eol_date=$(echo "$eol_data" | grep -o '"eol":"[^"]*"' | head -1 | cut -d'"' -f4)
            if [[ "$eol_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$eol_date" < "$today" ]]; then
                echo "${pkg_name}|${friendly_name}|${installed_version}|${eol_date}|unknown|EOL_CONFIRMED" >> "$outfile"
                SA_DEPRECATED=$(( SA_DEPRECATED + 1 ))
            fi
        fi
    done
    echo ""

    # Complementa com lista estática para pacotes sem entrada no endoflife.date
    _sa_static_deprecated_fallback "$outfile"

    local count
    count=$(wc -l < "$outfile")
    _sa_log "OK" "Pacotes EOL/depreciados detectados: ${_BOLD}${count}${_NC}"
}

# Fallback estático para protocolos inseguros que endoflife.date não cobre
_sa_static_deprecated_fallback() {
    local outfile="$1"
    local static_list=(
        "telnet|Telnet|any|N/A|openssh-client|INSECURE_PROTOCOL"
        "telnetd|Telnet Daemon|any|N/A|openssh-server|INSECURE_PROTOCOL"
        "rsh-client|RSH Client|any|N/A|openssh-client|INSECURE_PROTOCOL"
        "rsh-server|RSH Server|any|N/A|openssh-server|INSECURE_PROTOCOL"
        "rlogin|RLogin|any|N/A|openssh-client|INSECURE_PROTOCOL"
        "ftp|FTP Client|any|N/A|sftp|INSECURE_PROTOCOL"
        "ftpd|FTP Server|any|N/A|vsftpd|INSECURE_PROTOCOL"
        "ntp|NTP (legado)|any|N/A|chrony|DEPRECATED_REPLACED"
    )

    for entry in "${static_list[@]}"; do
        local pkg_name
        pkg_name=$(echo "$entry" | cut -d'|' -f1)
        if grep -q "^${pkg_name}\t" "${SA_TMP_DIR}/installed.txt" 2>/dev/null; then
            # Não duplica se já entrou pelo endoflife.date
            if ! grep -q "^${pkg_name}|" "$outfile" 2>/dev/null; then
                local installed_version
                installed_version=$(grep "^${pkg_name}\t" "${SA_TMP_DIR}/installed.txt" | awk '{print $2}' | head -1)
                local friendly eol_date latest status
                friendly=$(echo "$entry"   | cut -d'|' -f2)
                eol_date=$(echo "$entry"   | cut -d'|' -f4)
                latest=$(echo "$entry"     | cut -d'|' -f5)
                status=$(echo "$entry"     | cut -d'|' -f6)
                echo "${pkg_name}|${friendly}|${installed_version}|${eol_date}|${latest}|${status}" >> "$outfile"
                SA_DEPRECATED=$(( SA_DEPRECATED + 1 ))
            fi
        fi
    done
}

# ================================================================
# FASE 2B — CVE via OSV.dev + Ubuntu USN + Debian Security Tracker
# Melhoria 2: múltiplas fontes de CVE com cobertura complementar
# ================================================================

sa_fetch_vulnerabilities() {
    local outfile="${SA_TMP_DIR}/vulns.txt"
    > "$outfile"

    if ! command -v curl >/dev/null 2>&1; then
        _sa_log "WARN" "curl ausente — verificação de CVE online desabilitada."
        return 0
    fi

    # --- Fonte A: Gerenciador nativo (mais confiável, sempre primeiro) ---
    _sa_fetch_native_advisories "$outfile"

    # --- Fonte B: OSV.dev ---
    _sa_fetch_osv "$outfile"

    # --- Fonte C: Ubuntu USN / Debian Security Tracker ---
    _sa_fetch_distro_tracker "$outfile"

    # Deduplica por pacote mantendo a entrada de maior severidade
    sort -t'|' -k1,1 -k5,5rn "$outfile" 2>/dev/null \
        | awk -F'|' '!seen[$1]++' \
        > "${SA_TMP_DIR}/vulns_dedup.txt" || true
    mv "${SA_TMP_DIR}/vulns_dedup.txt" "$outfile"

    SA_VULNERABLE=$(wc -l < "$outfile")
    _sa_log "OK" "Vulnerabilidades únicas detectadas (total combinado): ${_BOLD}${SA_VULNERABLE}${_NC}"
}

_sa_fetch_native_advisories() {
    local outfile="$1"
    _sa_log "STEP" "Fonte A: Security advisories do gerenciador nativo..."
    local count=0

    case "$SA_PKG" in
        apt)
            while IFS= read -r line; do
                local pkg
                pkg=$(echo "$line" | awk '{print $2}')
                echo "${pkg}|native|SECURITY_UPDATE|HIGH|7.0|Atualização de segurança disponível no repositório|apt" >> "$outfile"
                count=$(( count + 1 ))
            done < <(apt-get -s dist-upgrade 2>/dev/null | grep "^Inst" | grep -i "security" || true)
            ;;
        dnf)
            while IFS= read -r line; do
                local pkg advisory severity
                pkg=$(echo "$line"      | awk '{print $3}')
                advisory=$(echo "$line" | awk '{print $1}')
                severity=$(echo "$line" | awk '{print $2}')
                echo "${pkg}|${advisory}|DNF_ADVISORY|${severity}|0|DNF Security Advisory|dnf" >> "$outfile"
                count=$(( count + 1 ))
            done < <(dnf updateinfo list security 2>/dev/null | grep -v "^$\|^Last\|^Loaded" || true)
            ;;
        yum)
            while IFS= read -r line; do
                local pkg advisory severity
                pkg=$(echo "$line"      | awk '{print $3}')
                advisory=$(echo "$line" | awk '{print $1}')
                severity=$(echo "$line" | awk '{print $2}')
                echo "${pkg}|${advisory}|YUM_ADVISORY|${severity}|0|YUM Security Advisory|yum" >> "$outfile"
                count=$(( count + 1 ))
            done < <(yum updateinfo list security 2>/dev/null | grep -v "^$\|^Loaded\|^Last" || true)
            ;;
    esac

    _sa_log "OK" "  Fonte A (nativo): ${count} advisory(s)"
}

_sa_fetch_osv() {
    local outfile="$1"
    _sa_log "STEP" "Fonte B: OSV.dev (Open Source Vulnerabilities)..."

    if ! _sa_curl "" "https://api.osv.dev" | grep -q "." 2>/dev/null; then
        _sa_log "WARN" "  Sem acesso a api.osv.dev — pulando."
        return 0
    fi

    local critical_pkgs=(
        "openssl" "libssl3" "libssl1.1" "libssl1.0" "libssl-dev"
        "openssh-server" "openssh-client" "openssh"
        "bash" "sudo" "glibc" "libc6" "libc-bin"
        "linux-image" "linux-libc-dev"
        "curl" "libcurl4" "libcurl3" "wget"
        "nginx" "apache2" "httpd" "lighttpd"
        "mysql-server" "mysql-client" "postgresql" "mariadb-server"
        "php" "php-common" "python3" "python3-minimal" "nodejs"
        "git" "git-core" "systemd" "systemd-sysv" "dbus"
        "nss" "libnss3" "libgnutls30" "libgcrypt20"
        "zip" "unzip" "tar" "gzip" "bzip2" "xz-utils"
        "vim" "vim-common" "nano" "less"
        "rsync" "samba" "nfs-kernel-server"
        "docker" "docker-ce" "containerd"
    )

    local ecosystem="Debian"
    case "$SA_PKG" in
        dnf|yum) ecosystem="Red Hat" ;;
        zypper)  ecosystem="openSUSE" ;;
    esac

    local checked=0 total=${#critical_pkgs[@]} osv_count=0

    for cp in "${critical_pkgs[@]}"; do
        checked=$(( checked + 1 ))
        _sa_progress "$checked" "$total" "OSV.dev"

        # Verifica se está instalado
        local installed_line
        installed_line=$(grep "^${cp}\t" "${SA_TMP_DIR}/installed.txt" 2>/dev/null | head -1) || true
        [ -z "$installed_line" ] && continue

        local pkg_version
        pkg_version=$(echo "$installed_line" | awk '{print $2}')

        local payload response
        payload="{\"version\":\"${pkg_version}\",\"package\":{\"name\":\"${cp}\",\"ecosystem\":\"${ecosystem}\"}}"
        response=$(_sa_curl '{"vulns":[]}' \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "https://api.osv.dev/v1/query")

        [[ "$response" == *'"vulns"'* ]] || continue

        if command -v jq >/dev/null 2>&1; then
            local vuln_count
            vuln_count=$(echo "$response" | jq '.vulns | length' 2>/dev/null) || vuln_count=0
            [ "${vuln_count:-0}" -eq 0 ] && continue

            # Itera cada vulnerabilidade individualmente
            local i
            for (( i=0; i<vuln_count && i<5; i++ )); do
                local cve_id severity_score severity_type fixed_version
                cve_id=$(echo "$response" | jq -r ".vulns[$i].id // \"UNKNOWN\"" 2>/dev/null) || cve_id="UNKNOWN"
                severity_score=$(echo "$response" | jq -r \
                    ".vulns[$i].severity[]? | select(.type==\"CVSS_V3\") | .score" \
                    2>/dev/null | head -1) || severity_score=""
                [ -z "$severity_score" ] && severity_score=$(echo "$response" | jq -r \
                    ".vulns[$i].severity[0]?.score // \"N/A\"" 2>/dev/null || echo "N/A")

                # Extrai versão corrigida do affected[].ranges
                fixed_version=$(echo "$response" | jq -r \
                    ".vulns[$i].affected[]?.ranges[]?.events[]? | select(.fixed != null) | .fixed" \
                    2>/dev/null | head -1) || fixed_version=""
                [ -z "$fixed_version" ] && fixed_version="latest"

                local cvss_num
                cvss_num=$(echo "$severity_score" | grep -o '[0-9]*\.[0-9]*' | head -1 || echo "0")
                local sev_label="MEDIUM"
                if command -v bc >/dev/null 2>&1; then
                    if   (( $(echo "$cvss_num >= 9.0" | bc -l 2>/dev/null || echo 0) )); then sev_label="CRITICAL"
                    elif (( $(echo "$cvss_num >= 7.0" | bc -l 2>/dev/null || echo 0) )); then sev_label="HIGH"
                    elif (( $(echo "$cvss_num >= 4.0" | bc -l 2>/dev/null || echo 0) )); then sev_label="MEDIUM"
                    else sev_label="LOW"
                    fi
                fi

                echo "${cp}|${cve_id}|OSV|${sev_label}|${cvss_num}|${pkg_version}|${fixed_version}|osv" >> "$outfile"
                osv_count=$(( osv_count + 1 ))
            done
        else
            # Sem jq
            if echo "$response" | grep -q '"id"'; then
                local cve_id
                cve_id=$(echo "$response" | grep -o '"CVE-[0-9-]*"' | head -1 | tr -d '"') || cve_id="UNKNOWN"
                [ -n "$cve_id" ] && \
                    echo "${cp}|${cve_id}|OSV|MEDIUM|5.0|${pkg_version}|latest|osv" >> "$outfile" && \
                    osv_count=$(( osv_count + 1 ))
            fi
        fi
    done
    echo ""
    _sa_log "OK" "  Fonte B (OSV.dev): ${osv_count} CVE(s)"
}

_sa_fetch_distro_tracker() {
    local outfile="$1"
    _sa_log "STEP" "Fonte C: Distro Security Tracker (USN/DSA)..."
    local count=0

    # Detecta distro
    local distro_id
    distro_id=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]') || distro_id=""

    case "$distro_id" in
        ubuntu)
            # Ubuntu Security Notices: API JSON por pacote
            # https://ubuntu.com/security/cves?package=PKG&limit=5
            local key_pkgs=("openssl" "openssh-server" "bash" "sudo" "curl" "nginx" "apache2" "python3" "git" "systemd")
            for pkg in "${key_pkgs[@]}"; do
                grep -q "^${pkg}\t" "${SA_TMP_DIR}/installed.txt" 2>/dev/null || continue

                local usn_data
                usn_data=$(_sa_curl '{"notices":[]}' \
                    "https://ubuntu.com/security/cves.json?package=${pkg}&limit=5&order=oldest-fixed")

                if command -v jq >/dev/null 2>&1 && echo "$usn_data" | jq -e '.cves | length > 0' >/dev/null 2>&1; then
                    local installed_version
                    installed_version=$(grep "^${pkg}\t" "${SA_TMP_DIR}/installed.txt" | awk '{print $2}' | head -1)

                    local cve_count
                    cve_count=$(echo "$usn_data" | jq '.cves | length' 2>/dev/null || echo 0)
                    local i
                    for (( i=0; i<cve_count && i<3; i++ )); do
                        local cve_id severity description
                        cve_id=$(echo "$usn_data" | jq -r ".cves[$i].name // \"UNKNOWN\"" 2>/dev/null)
                        severity=$(echo "$usn_data" | jq -r ".cves[$i].ubuntu_description // \"N/A\"" 2>/dev/null | head -c 80)
                        description="Ubuntu Security Notice"

                        # Verifica se CVE já está nos resultados (deduplication prévia)
                        grep -q "^${pkg}|${cve_id}|" "$outfile" 2>/dev/null && continue

                        echo "${pkg}|${cve_id}|USN|MEDIUM|5.0|${installed_version}|latest|ubuntu_usn" >> "$outfile"
                        count=$(( count + 1 ))
                    done
                fi
            done
            ;;

        debian)
            # Debian Security Tracker JSON
            # https://security-tracker.debian.org/tracker/data/json — arquivo grande, usa por pacote
            local key_pkgs=("openssl" "openssh" "bash" "sudo" "curl" "nginx" "apache2" "python3" "git" "systemd")
            for pkg in "${key_pkgs[@]}"; do
                grep -q "^${pkg}\t" "${SA_TMP_DIR}/installed.txt" 2>/dev/null || continue

                local dsa_data
                dsa_data=$(_sa_curl '{}' \
                    "https://security-tracker.debian.org/tracker/data/json/source/${pkg}")

                if command -v jq >/dev/null 2>&1 && echo "$dsa_data" | jq -e 'keys | length > 0' >/dev/null 2>&1; then
                    local installed_version
                    installed_version=$(grep "^${pkg}\t" "${SA_TMP_DIR}/installed.txt" | awk '{print $2}' | head -1)

                    while IFS= read -r cve_id; do
                        grep -q "^${pkg}|${cve_id}|" "$outfile" 2>/dev/null && continue
                        local urgency
                        urgency=$(echo "$dsa_data" | jq -r ".\"${cve_id}\".urgency // \"low\"" 2>/dev/null | head -1)
                        local sev="MEDIUM"
                        case "$urgency" in
                            high|unimportant) sev="HIGH" ;;
                            medium)           sev="MEDIUM" ;;
                            low|*)            sev="LOW" ;;
                        esac
                        echo "${pkg}|${cve_id}|DSA|${sev}|5.0|${installed_version}|latest|debian_tracker" >> "$outfile"
                        count=$(( count + 1 ))
                    done < <(echo "$dsa_data" | jq -r 'keys[]' 2>/dev/null | head -5 || true)
                fi
            done
            ;;

        *)
            _sa_log "INFO" "  Distro tracker: sem suporte direto para '${distro_id}' — usando apenas OSV.dev e nativo."
            ;;
    esac

    _sa_log "OK" "  Fonte C (distro tracker): ${count} CVE(s) adicionais"
}

# ================================================================
# FASE 3 — ANÁLISE DE ESTABILIDADE
# Melhoria 4: simulação real com apt -s antes de qualquer mudança
# ================================================================

sa_analyze_stability() {
    local pkg_name="$1"
    local new_version="${2:-}"
    local dependents_count=0 risk_level="LOW"
    local sim_conflicts="" sim_removals=0

    # Conta dependentes reversos
    case "$SA_PKG" in
        apt)
            dependents_count=$(apt-cache rdepends "$pkg_name" 2>/dev/null \
                | grep -v "^$\|Reverse\|${pkg_name}" | wc -l) || dependents_count=0
            ;;
        dnf|yum)
            dependents_count=$(rpm -q --whatrequires "$pkg_name" 2>/dev/null \
                | grep -v "no package" | wc -l) || dependents_count=0
            ;;
    esac

    # Melhoria 4: simulação do upgrade para detectar conflitos reais
    if [ "$SA_PKG" = "apt" ]; then
        local sim_output
        if [ -n "$new_version" ]; then
            sim_output=$(apt-get -s install "${pkg_name}=${new_version}" 2>&1) || sim_output=""
        else
            sim_output=$(apt-get -s install "$pkg_name" 2>&1) || sim_output=""
        fi

        sim_conflicts=$(echo "$sim_output" | grep -i "conflict\|broken\|held back\|not installable" || true)
        sim_removals=$(echo "$sim_output" | grep -c "^Remv " || true)

        # Se simulação detectou conflitos, eleva o risco automaticamente
        if [ -n "$sim_conflicts" ]; then
            echo "${dependents_count}|CRITICAL|CONFLICT_DETECTED|${sim_conflicts}"
            return 0
        fi
        if [ "$sim_removals" -gt 3 ]; then
            echo "${dependents_count}|HIGH|${sim_removals}_REMOVALS|"
            return 0
        fi
    fi

    if   [ "$dependents_count" -gt $(( SA_STABILITY_THRESHOLD * 4 )) ]; then risk_level="CRITICAL"
    elif [ "$dependents_count" -gt $(( SA_STABILITY_THRESHOLD * 2 )) ]; then risk_level="HIGH"
    elif [ "$dependents_count" -gt "$SA_STABILITY_THRESHOLD" ];          then risk_level="MEDIUM"
    fi

    echo "${dependents_count}|${risk_level}||"
}

# ================================================================
# FASE 4 — PINNING DE VERSÃO SEGURA
# Melhoria 3: instala a versão mínima segura, não só "a mais nova"
# ================================================================

sa_resolve_safe_version() {
    local pkg_name="$1"
    local cve_fixed_version="${2:-}"    # versão onde o CVE foi corrigido (do OSV)
    local safe_version="" method=""

    case "$SA_PKG" in
        apt)
            # Lista todas as versões disponíveis no repositório
            local available_versions
            available_versions=$(apt-cache madison "$pkg_name" 2>/dev/null \
                | awk '{print $3}' | sort -V) || available_versions=""

            if [ -z "$available_versions" ]; then
                echo "latest||not_found"
                return 0
            fi

            if [ -n "$cve_fixed_version" ] && [ "$cve_fixed_version" != "latest" ]; then
                # Encontra a menor versão >= cve_fixed_version disponível no repositório
                while IFS= read -r ver; do
                    if dpkg --compare-versions "$ver" ge "$cve_fixed_version" 2>/dev/null; then
                        safe_version="$ver"
                        method="pinned_to_fix"
                        break
                    fi
                done <<< "$available_versions"
            fi

            # Fallback: versão mais recente do repositório de segurança
            if [ -z "$safe_version" ]; then
                safe_version=$(apt-cache madison "$pkg_name" 2>/dev/null \
                    | grep "security" \
                    | awk '{print $3}' | sort -V | tail -1) || safe_version=""
                [ -n "$safe_version" ] && method="latest_security_repo"
            fi

            # Último fallback: versão mais recente disponível
            if [ -z "$safe_version" ]; then
                safe_version=$(echo "$available_versions" | tail -1)
                method="latest_available"
            fi
            ;;

        dnf|yum)
            safe_version=$(dnf info "$pkg_name" 2>/dev/null \
                | grep "^Version" | awk '{print $3}' | head -1) || safe_version="latest"
            method="latest_available"
            ;;

        *)
            safe_version="latest"
            method="unknown"
            ;;
    esac

    echo "${safe_version}|${method}"
}

# ================================================================
# FASE 5 — APLICAÇÃO DE CORREÇÕES COM PINNING
# Melhoria 3+4: aplica versão específica após simulação bem-sucedida
# ================================================================

sa_apply_fixes() {
    local dry_run="${1:-false}"
    local fixes_file="${SA_TMP_DIR}/fixes_to_apply.txt"
    > "$fixes_file"

    _sa_log "STEP" "Preparando lista de correções com versão segura..."

    # Monta lista de pacotes vulneráveis com versão segura resolvida
    if [ -f "${SA_TMP_DIR}/vulns.txt" ]; then
        while IFS='|' read -r pkg_name cve_id source severity cvss installed_version fixed_version origin; do
            [ -z "$pkg_name" ] && continue

            # Resolve versão segura (Melhoria 3)
            local safe_info safe_ver safe_method
            safe_info=$(sa_resolve_safe_version "$pkg_name" "$fixed_version")
            safe_ver=$(echo "$safe_info"    | cut -d'|' -f1)
            safe_method=$(echo "$safe_info" | cut -d'|' -f2)

            # Simula antes de planejar (Melhoria 4)
            local stability_info stability_risk sim_issue
            stability_info=$(sa_analyze_stability "$pkg_name" "$safe_ver")
            stability_risk=$(echo "$stability_info" | cut -d'|' -f2)
            sim_issue=$(echo "$stability_info"      | cut -d'|' -f3)

            if [ "$stability_risk" = "CRITICAL" ] || [ "$sim_issue" = "CONFLICT_DETECTED" ]; then
                _sa_log "WARN" "  PULANDO ${pkg_name}: simulação detectou conflito — ${sim_issue}"
                SA_SKIPPED=$(( SA_SKIPPED + 1 ))
                echo "${pkg_name}|${safe_ver}|SKIPPED|${sim_issue}" >> "$fixes_file"
                continue
            fi

            echo "${pkg_name}|${safe_ver}|${safe_method}|${stability_risk}" >> "$fixes_file"
        done < "${SA_TMP_DIR}/vulns.txt"
    fi

    if [ ! -s "$fixes_file" ]; then
        _sa_log "OK" "Nenhuma correção a aplicar."
        return 0
    fi

    _sa_log "STEP" "Aplicando correções..."

    while IFS='|' read -r pkg_name safe_ver method risk; do
        [ "$method" = "SKIPPED" ] && continue

        if [ "$dry_run" = true ]; then
            _sa_log "INFO" "  [DRY-RUN] ${pkg_name} → ${safe_ver} (método: ${method}, risco: ${risk})"
            continue
        fi

        case "$SA_PKG" in
            apt)
                local install_target
                if [ "$safe_ver" = "latest" ] || [ "$method" = "latest_available" ]; then
                    install_target="$pkg_name"
                else
                    install_target="${pkg_name}=${safe_ver}"
                fi

                _sa_log "INFO" "  Instalando: ${install_target} (${method})..."
                if DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    -o Dpkg::Options::="--force-confdef" \
                    -o Dpkg::Options::="--force-confold" \
                    "$install_target" >> "$SA_LOG_FILE" 2>&1; then
                    _sa_log "OK"   "  ✅ ${pkg_name} atualizado para ${safe_ver}"
                    SA_UPDATED=$(( SA_UPDATED + 1 ))
                else
                    _sa_log "WARN" "  ⚠️  Falha ao instalar ${install_target} — tentando versão mais recente..."
                    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg_name" >> "$SA_LOG_FILE" 2>&1; then
                        _sa_log "OK"   "  ✅ ${pkg_name} atualizado (versão mais recente)"
                        SA_UPDATED=$(( SA_UPDATED + 1 ))
                    else
                        _sa_log "ERROR" "  ❌ Falha ao atualizar ${pkg_name}"
                        SA_SKIPPED=$(( SA_SKIPPED + 1 ))
                    fi
                fi
                ;;
            dnf)
                if dnf upgrade -y "$pkg_name" >> "$SA_LOG_FILE" 2>&1; then
                    _sa_log "OK" "  ✅ ${pkg_name} atualizado"
                    SA_UPDATED=$(( SA_UPDATED + 1 ))
                else
                    SA_SKIPPED=$(( SA_SKIPPED + 1 ))
                fi
                ;;
            yum)
                if yum update -y "$pkg_name" >> "$SA_LOG_FILE" 2>&1; then
                    _sa_log "OK" "  ✅ ${pkg_name} atualizado"
                    SA_UPDATED=$(( SA_UPDATED + 1 ))
                else
                    SA_SKIPPED=$(( SA_SKIPPED + 1 ))
                fi
                ;;
        esac
    done < "$fixes_file"

    # Remove orfãos que possam ter vulnerabilidades
    if [ "$dry_run" = false ] && [ "$SA_PKG" = "apt" ]; then
        _sa_log "STEP" "Removendo pacotes orfãos..."
        apt-get autoremove -y >> "$SA_LOG_FILE" 2>&1 || true
    fi
}

# ================================================================
# FASE 6 — CICLO RECURSIVO DE MELHORIA
# ================================================================

sa_recursive_cycle() {
    SA_RECURSIVE_CYCLE=$(( SA_RECURSIVE_CYCLE + 1 ))
    _sa_log "AUDIT" "=== Ciclo recursivo #${SA_RECURSIVE_CYCLE}/${SA_RECURSIVE_MAX} ==="

    if [ "$SA_RECURSIVE_CYCLE" -gt "$SA_RECURSIVE_MAX" ]; then
        _sa_log "OK" "Máximo de ciclos atingido. Sistema estável."
        echo "max_cycles_reached" > "${SA_TMP_DIR}/recursive_status.txt"
        return 0
    fi

    # Re-verifica pacotes vulneráveis após as correções
    local recheck="${SA_TMP_DIR}/vulns_recheck.txt"
    > "$recheck"

    case "$SA_PKG" in
        apt)
            apt-get -s dist-upgrade 2>/dev/null \
                | grep "^Inst" | grep -i "security" \
                | awk '{print $2}' > "$recheck" || true
            ;;
        dnf)
            dnf check-update --security --quiet 2>/dev/null \
                | grep -v "^$\|^Last\|^Loaded" \
                | awk '{print $1}' > "$recheck" || true
            ;;
    esac

    local remaining
    remaining=$(wc -l < "$recheck")

    if [ "$remaining" -eq 0 ]; then
        _sa_log "OK" "Ciclo #${SA_RECURSIVE_CYCLE}: sistema convergiu — sem vulnerabilidades residuais."
        echo "converged" > "${SA_TMP_DIR}/recursive_status.txt"
        return 0
    fi

    _sa_log "WARN" "Ciclo #${SA_RECURSIVE_CYCLE}: ${remaining} pacote(s) ainda vulnerável(is) — re-aplicando correções."
    echo "pending:${remaining}" > "${SA_TMP_DIR}/recursive_status.txt"

    # Atualiza lista de vulneráveis e aplica nova rodada
    cp "$recheck" "${SA_TMP_DIR}/vulns_residual.txt"
    while IFS= read -r pkg_name; do
        local safe_info safe_ver
        safe_info=$(sa_resolve_safe_version "$pkg_name" "")
        safe_ver=$(echo "$safe_info" | cut -d'|' -f1)
        echo "${pkg_name}|${safe_ver}|latest_security_repo|LOW" >> "${SA_TMP_DIR}/fixes_residual.txt"
    done < "$recheck"

    if [ -s "${SA_TMP_DIR}/fixes_residual.txt" ]; then
        while IFS='|' read -r pkg_name safe_ver method risk; do
            if [ "$SA_PKG" = "apt" ]; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg_name" >> "$SA_LOG_FILE" 2>&1 && \
                    _sa_log "OK" "  ✅ ${pkg_name} corrigido no ciclo #${SA_RECURSIVE_CYCLE}" || true
            fi
        done < "${SA_TMP_DIR}/fixes_residual.txt"
    fi

    sa_recursive_cycle
}

# ================================================================
# GERAÇÃO DO RELATÓRIO MARKDOWN
# ================================================================

sa_generate_report() {
    local pkg_mgr="$1"
    _sa_log "STEP" "Gerando relatório Markdown em ${SA_REPORT_FILE}..."

    local hostname os_info kernel report_ts
    hostname=$(hostname 2>/dev/null || echo "unknown")
    os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "Linux")
    kernel=$(uname -r)
    report_ts=$(date '+%d/%m/%Y às %H:%M:%S')

    # Recalcula contadores finais a partir dos arquivos
    SA_VULNERABLE=$(wc -l < "${SA_TMP_DIR}/vulns.txt" 2>/dev/null || echo 0)
    SA_CRITICAL=$(grep -c "|CRITICAL|" "${SA_TMP_DIR}/vulns.txt" 2>/dev/null || true)
    SA_CRITICAL=${SA_CRITICAL:-0}
    SA_HIGH=$(grep -c "|HIGH|"     "${SA_TMP_DIR}/vulns.txt" 2>/dev/null || true)
    SA_HIGH=${SA_HIGH:-0}

    # Score de risco
    local score=0
    score=$(( score + SA_CRITICAL  * 25 ))
    score=$(( score + SA_HIGH      * 15 ))
    score=$(( score + SA_VULNERABLE * 5 ))
    score=$(( score + SA_DEPRECATED * 3 ))
    score=$(( score + SA_OUTDATED       ))
    [ "$score" -gt 100 ] && score=100

    local risk_level risk_desc
    if   [ "$score" -ge 75 ]; then risk_level="🔴 CRÍTICO"; risk_desc="Vulnerabilidades críticas — ação imediata necessária."
    elif [ "$score" -ge 50 ]; then risk_level="🟠 ALTO";    risk_desc="Vulnerabilidades significativas — ação urgente recomendada."
    elif [ "$score" -ge 25 ]; then risk_level="🟡 MÉDIO";   risk_desc="Vulnerabilidades moderadas — planejamento de correção recomendado."
    else                            risk_level="🟢 BAIXO";   risk_desc="Boa postura de segurança."
    fi

    local recursive_status="N/A"
    [ -f "${SA_TMP_DIR}/recursive_status.txt" ] && \
        recursive_status=$(cat "${SA_TMP_DIR}/recursive_status.txt")

    # ---------- CABEÇALHO ----------
    cat > "$SA_REPORT_FILE" << EOF
# 🔐 Relatório de Auditoria de Segurança de Pacotes

> **Gerado em:** ${report_ts}
> **Host:** \`${hostname}\`
> **Sistema:** ${os_info}
> **Kernel:** \`${kernel}\`
> **Gerenciador:** \`${pkg_mgr}\`
> **Fontes CVE:** Gerenciador nativo · OSV.dev · $(grep -q "ubuntu" /etc/os-release 2>/dev/null && echo "Ubuntu USN" || echo "Debian Security Tracker")
> **Ciclos recursivos:** ${SA_RECURSIVE_CYCLE} de ${SA_RECURSIVE_MAX}

---

## 📊 Sumário Executivo

| Métrica | Valor |
|---------|-------|
| Total de pacotes analisados | **${SA_TOTAL}** |
| Pacotes desatualizados | **${SA_OUTDATED}** |
| Pacotes vulneráveis (CVE) | **${SA_VULNERABLE}** |
| Vulnerabilidades críticas (CVSS ≥ 9.0) | **${SA_CRITICAL}** |
| Vulnerabilidades altas (CVSS ≥ 7.0) | **${SA_HIGH}** |
| Pacotes EOL / depreciados | **${SA_DEPRECATED}** |
| Correções aplicadas | **${SA_UPDATED}** |
| Pacotes ignorados (risco de conflito) | **${SA_SKIPPED}** |

### 🎯 Score de Risco Global: ${score}/100 — ${risk_level}

> ${risk_desc}

---

## 🚨 Vulnerabilidades Detectadas

EOF

    # ---------- TABELA DE CVEs ----------
    if [ ! -s "${SA_TMP_DIR}/vulns.txt" ]; then
        echo "_Nenhuma vulnerabilidade detectada._" >> "$SA_REPORT_FILE"
    else
        cat >> "$SA_REPORT_FILE" << 'EOF'
| Pacote | CVE / Advisory | Fonte | Severidade | CVSS | Versão Instalada | Versão Segura |
|--------|---------------|-------|-----------|------|-----------------|--------------|
EOF
        while IFS='|' read -r pkg_name cve_id source severity cvss installed_version fixed_version origin; do
            local sev_icon="⚪"
            case "$severity" in
                CRITICAL) sev_icon="🔴" ;;
                HIGH)     sev_icon="🟠" ;;
                MEDIUM)   sev_icon="🟡" ;;
                LOW)      sev_icon="🟢" ;;
            esac

            # Resolve versão segura para o relatório
            local safe_info safe_ver safe_method
            safe_info=$(sa_resolve_safe_version "$pkg_name" "$fixed_version")
            safe_ver=$(echo "$safe_info"    | cut -d'|' -f1)
            safe_method=$(echo "$safe_info" | cut -d'|' -f2)

            local safe_display="${safe_ver}"
            [ "$safe_method" = "pinned_to_fix" ] && safe_display="\`${safe_ver}\` _(fix exato)_"
            [ "$safe_method" = "latest_security_repo" ] && safe_display="\`${safe_ver}\` _(repo security)_"
            [ "$safe_method" = "latest_available" ] && safe_display="\`${safe_ver}\` _(mais recente)_"

            printf '| `%s` | `%s` | %s | %s %s | %s | `%s` | %s |\n' \
                "$pkg_name" "$cve_id" "$source" "$sev_icon" "$severity" \
                "${cvss:-N/A}" "${installed_version}" "$safe_display" \
                >> "$SA_REPORT_FILE"
        done < "${SA_TMP_DIR}/vulns.txt"
    fi

    printf '\n---\n\n' >> "$SA_REPORT_FILE"

    # ---------- SEÇÃO EOL / DEPRECIADOS ----------
    cat >> "$SA_REPORT_FILE" << 'EOF'
## ⚠️ Pacotes EOL e Depreciados

> Dados de EOL obtidos dinamicamente via [endoflife.date](https://endoflife.date)

| Pacote | Nome | Versão Instalada | Data EOL | Substituto / Versão Segura | Status |
|--------|------|-----------------|----------|--------------------------|--------|
EOF

    if [ ! -s "${SA_TMP_DIR}/eol_results.txt" ]; then
        echo "| — | — | — | — | — | ✅ Nenhum pacote EOL detectado |" >> "$SA_REPORT_FILE"
    else
        while IFS='|' read -r pkg_name friendly installed_version eol_date latest status; do
            local status_icon action
            case "$status" in
                EOL_CONFIRMED)     status_icon="🔴"; action="Substituição urgente" ;;
                EOL_SOON_*)
                    local days="${status#EOL_SOON_}"; days="${days%d}"
                    status_icon="🟠"; action="EOL em ${days} dias" ;;
                INSECURE_PROTOCOL) status_icon="🔴"; action="Remover imediatamente" ;;
                DEPRECATED_REPLACED) status_icon="🟡"; action="Migrar para substituto" ;;
                *)                 status_icon="🟡"; action="Revisar" ;;
            esac
            printf '| `%s` | %s | `%s` | `%s` | `%s` | %s %s |\n' \
                "$pkg_name" "$friendly" "$installed_version" \
                "$eol_date" "$latest" "$status_icon" "$action" \
                >> "$SA_REPORT_FILE"
        done < "${SA_TMP_DIR}/eol_results.txt"
    fi

    printf '\n---\n\n' >> "$SA_REPORT_FILE"

    # ---------- SEÇÃO PACOTES DESATUALIZADOS COM ANÁLISE DE ESTABILIDADE ----------
    cat >> "$SA_REPORT_FILE" << 'EOF'
## 📦 Pacotes Desatualizados

> Análise de estabilidade inclui simulação de upgrade (`apt-get -s`) para detectar conflitos reais.

| Pacote | Nova Versão | Dependentes | Risco | Simulação | Recomendação |
|--------|------------|------------|-------|-----------|-------------|
EOF

    if [ ! -s "${SA_TMP_DIR}/outdated.txt" ]; then
        echo "| — | — | — | — | — | ✅ Todos os pacotes estão na última versão |" >> "$SA_REPORT_FILE"
    else
        local count=0 total
        total=$(wc -l < "${SA_TMP_DIR}/outdated.txt")
        while IFS=$'\t' read -r pkg_name new_version _; do
            count=$(( count + 1 ))
            _sa_progress "$count" "$total" "Analisando estabilidade"

            local stab_info n_dep risk sim_issue
            stab_info=$(sa_analyze_stability "$pkg_name" "$new_version")
            n_dep=$(echo "$stab_info"    | cut -d'|' -f1)
            risk=$(echo "$stab_info"     | cut -d'|' -f2)
            sim_issue=$(echo "$stab_info"| cut -d'|' -f3)

            local risk_icon="🟢" sim_status="✅ OK" recommendation="Atualizar"
            case "$risk" in
                CRITICAL) risk_icon="🔴"; recommendation="⚠️ Testar em staging" ;;
                HIGH)     risk_icon="🟠"; recommendation="🔍 Revisar changelog" ;;
                MEDIUM)   risk_icon="🟡"; recommendation="📋 Atualizar com monitoramento" ;;
            esac
            if [ "$sim_issue" = "CONFLICT_DETECTED" ]; then
                sim_status="❌ Conflito"
                recommendation="🛑 Não atualizar sem revisão manual"
            elif echo "$sim_issue" | grep -q "_REMOVALS"; then
                local n="${sim_issue%%_*}"
                sim_status="⚠️ ${n} remoções"
            fi

            printf '| `%s` | `%s` | %s | %s %s | %s | %s |\n' \
                "$pkg_name" "$new_version" "$n_dep" \
                "$risk_icon" "$risk" "$sim_status" "$recommendation" \
                >> "$SA_REPORT_FILE"
        done < "${SA_TMP_DIR}/outdated.txt"
        echo ""
    fi

    printf '\n---\n\n' >> "$SA_REPORT_FILE"

    # ---------- CORREÇÕES APLICADAS ----------
    cat >> "$SA_REPORT_FILE" << 'EOF'
## 🔧 Correções Aplicadas

| Pacote | Versão Segura | Método de Seleção | Resultado |
|--------|--------------|------------------|----------|
EOF

    if [ ! -s "${SA_TMP_DIR}/fixes_to_apply.txt" ]; then
        echo "| — | — | — | Nenhuma correção foi solicitada |" >> "$SA_REPORT_FILE"
    else
        while IFS='|' read -r pkg_name safe_ver method result; do
            local result_icon="✅"
            [ "$method" = "SKIPPED" ] && result_icon="⏭️"
            printf '| `%s` | `%s` | %s | %s %s |\n' \
                "$pkg_name" "$safe_ver" "$method" "$result_icon" "${result:-aplicado}" \
                >> "$SA_REPORT_FILE"
        done < "${SA_TMP_DIR}/fixes_to_apply.txt"
    fi

    printf '\n---\n\n' >> "$SA_REPORT_FILE"

    # ---------- HARDENING CHECKLIST ----------
    local ssh_root="⚠️ Não verificado" ssh_passwd="⚠️ Não verificado" fw_status="⚠️ Não verificado"

    if [ -f /etc/ssh/sshd_config ]; then
        grep -q "^PermitRootLogin no"          /etc/ssh/sshd_config 2>/dev/null \
            && ssh_root="✅ Desabilitado"   || ssh_root="⚠️ Verificar PermitRootLogin"
        grep -q "^PasswordAuthentication no"   /etc/ssh/sshd_config 2>/dev/null \
            && ssh_passwd="✅ Apenas chaves SSH" || ssh_passwd="⚠️ Senha habilitada"
    fi

    if   command -v ufw >/dev/null 2>&1; then
        ufw status 2>/dev/null | grep -q "active" && fw_status="✅ UFW ativo" || fw_status="🔴 UFW inativo"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --state 2>/dev/null | grep -q "running" && fw_status="✅ firewalld ativo" || fw_status="🔴 firewalld inativo"
    fi

    cat >> "$SA_REPORT_FILE" << EOF
## 🔒 Checklist de Hardening

| Item | Status | Detalhe |
|------|--------|---------|
| SSH Root Login | ${ssh_root} | /etc/ssh/sshd_config → PermitRootLogin |
| SSH Autenticação | ${ssh_passwd} | Preferir chave pública sobre senha |
| Firewall | ${fw_status} | UFW / firewalld / nftables |
| sudo NOPASSWD | ⚠️ Revisar | \`grep -r NOPASSWD /etc/sudoers*\` |
| Política de senha | ⚠️ Revisar | /etc/pam.d/common-password |
| Serviços expostos | ⚠️ Revisar | \`ss -tulnp\` |

---

## 📋 Metadados

| Item | Detalhe |
|------|---------|
| Módulo | security_audit.sh v2.0 |
| Ciclos recursivos | ${SA_RECURSIVE_CYCLE} de ${SA_RECURSIVE_MAX} |
| Status convergência | \`${recursive_status}\` |
| Log da auditoria | \`${SA_LOG_FILE}\` |
| Próxima auditoria | $(date -d "+30 days" '+%d/%m/%Y' 2>/dev/null || date -v+30d '+%d/%m/%Y' 2>/dev/null || echo "Em 30 dias") |

---
*Gerado pelo Linux System Manager — security_audit.sh v2.0*
*CVE data: OSV.dev · $(grep -q ubuntu /etc/os-release 2>/dev/null && echo "Ubuntu USN" || echo "Debian Security Tracker") · EOL: endoflife.date*
EOF

    _sa_log "OK" "Relatório salvo: ${_BOLD}${SA_REPORT_FILE}${_NC}"
}

# ================================================================
# FUNÇÕES DE RELATÓRIO PARA O MENU DO SISTEMA
# ================================================================

sa_view_last_report() {
    local last
    last=$(ls -t "${SA_AUDIT_DIR}"/security_report_*.md 2>/dev/null | head -1) || true
    if [ -z "${last:-}" ]; then
        echo -e "${_Y}Nenhum relatório encontrado. Execute uma auditoria primeiro.${_NC}"
        return 0
    fi
    echo -e "\n${_BOLD}${_M}📄 Último relatório:${_NC} ${last}\n"
    command -v less >/dev/null 2>&1 && less "$last" || cat "$last"
}

sa_list_reports() {
    echo -e "\n${_BOLD}${_M}📁 Relatórios disponíveis:${_NC}\n"
    local reports
    reports=$(ls -t "${SA_AUDIT_DIR}"/security_report_*.md 2>/dev/null) || true
    if [ -z "${reports:-}" ]; then
        echo -e "${_Y}Nenhum relatório encontrado.${_NC}"
        return 0
    fi
    printf '%-55s %-8s %s\n' "Arquivo" "Tamanho" "Data"
    printf '%.0s─' {1..75}; echo
    ls -lht "${SA_AUDIT_DIR}"/security_report_*.md 2>/dev/null \
        | awk '{printf "%-55s %-8s %s %s\n", $9, $5, $6" "$7, $8}'
    echo ""
}

# ================================================================
# ORQUESTRADOR PRINCIPAL — exposto ao sistema_manager como sa_run_audit
# ================================================================

sa_run_audit() {
    local dry_run="${1:-false}"
    local apply_fixes="${2:-false}"

    # Sincroniza SA_PKG do pai (PKG já foi definido por detect_package_manager)
    SA_PKG="${PKG:-unknown}"
    SA_DRY_RUN="$dry_run"

    # Reinicia contadores para permitir múltiplas execuções na mesma sessão
    SA_TOTAL=0; SA_OUTDATED=0; SA_VULNERABLE=0; SA_CRITICAL=0
    SA_HIGH=0;  SA_DEPRECATED=0; SA_UPDATED=0;  SA_SKIPPED=0
    SA_RECURSIVE_CYCLE=0
    SA_REPORT_DATE=$(date '+%Y%m%d_%H%M%S')
    SA_REPORT_FILE="${SA_AUDIT_DIR}/security_report_${SA_REPORT_DATE}.md"

    mkdir -p "$SA_AUDIT_DIR"

    _sa_log "AUDIT" "════════════════════════════════════════════"
    _sa_log "AUDIT" "   AUDITORIA DE SEGURANÇA v2.0 INICIADA"
    _sa_log "AUDIT" "   Gerenciador: ${SA_PKG} | DRY-RUN: ${dry_run}"
    _sa_log "AUDIT" "════════════════════════════════════════════"
    echo ""

    sa_check_deps || return 1

    # --- FASE 1: Coleta ---
    _sa_log "STEP" "━━━ FASE 1: Coleta de Dados ━━━"
    sa_collect_installed
    sa_collect_outdated

    # --- FASE 2: Análise de Vulnerabilidades (3 fontes) ---
    echo ""
    _sa_log "STEP" "━━━ FASE 2: Análise de Vulnerabilidades ━━━"
    sa_fetch_vulnerabilities

    # --- FASE 3: EOL dinâmico ---
    echo ""
    _sa_log "STEP" "━━━ FASE 3: Verificação de EOL (endoflife.date) ━━━"
    sa_fetch_eol_data

    # --- FASE 4+5: Correções com pinning e simulação ---
    if [ "$apply_fixes" = true ]; then
        echo ""
        _sa_log "STEP" "━━━ FASE 4: Aplicação de Correções (com pinning e simulação) ━━━"
        sa_apply_fixes "$dry_run"

        echo ""
        _sa_log "STEP" "━━━ FASE 5: Ciclo Recursivo de Verificação ━━━"
        sa_recursive_cycle
    fi

    # --- FASE 6: Relatório ---
    echo ""
    _sa_log "STEP" "━━━ FASE 6: Geração do Relatório Markdown ━━━"
    sa_generate_report "$SA_PKG"

    # --- Resumo final ---
    echo ""
    _sa_log "OK" "════════════════════════════════════════════"
    _sa_log "OK" "   AUDITORIA CONCLUÍDA"
    _sa_log "OK" "════════════════════════════════════════════"
    echo ""
    _sa_log "INFO" "📄 Relatório: ${_BOLD}${SA_REPORT_FILE}${_NC}"
    echo ""

    # _sa_summary_line: alinhamento manual por espaços (evita bug de printf com chars multibyte)
    # printf %-Ns conta bytes, não caracteres visuais — chars UTF-8 como ≥ deslocam o padding
    _sa_summary_line() {
        local label="$1" value="$2" color="${3:-$_NC}"
        local pad=38
        local label_len=${#label}
        local spaces=$(( pad - label_len ))
        [ "$spaces" -lt 1 ] && spaces=1
        printf "   %s%*s${color}%s${_NC}\n" "$label" "$spaces" "" "$value"
    }

    _sa_summary_line "Pacotes totais:"         "$SA_TOTAL"      "$_BOLD"
    _sa_summary_line "Desatualizados:"         "$SA_OUTDATED"   "$_Y"
    _sa_summary_line "Vulneraveis (CVE):"      "$SA_VULNERABLE" "$_R"
    _sa_summary_line "Criticos (CVSS >= 9.0):" "$SA_CRITICAL"   "$_R"
    _sa_summary_line "EOL / Depreciados:"      "$SA_DEPRECATED" "$_Y"
    if [ "$apply_fixes" = true ]; then
        _sa_summary_line "Correcoes aplicadas:"  "$SA_UPDATED" "$_G"
        _sa_summary_line "Ignorados (conflito):" "$SA_SKIPPED" "$_Y"
    fi
    echo ""
}

# ================================================================
# ENTRY POINT — quando executado diretamente (não como módulo)
# ================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail

    if [ "$EUID" -ne 0 ]; then
        echo -e "${_R}[ERRO]${_NC} Execute como root ou com sudo."
        exit 1
    fi

    # Detecta gerenciador de pacotes se não herdado
    if [ "${SA_PKG}" = "unknown" ]; then
        if   command -v apt    >/dev/null 2>&1; then SA_PKG="apt"
        elif command -v dnf    >/dev/null 2>&1; then SA_PKG="dnf"
        elif command -v yum    >/dev/null 2>&1; then SA_PKG="yum"
        elif command -v zypper >/dev/null 2>&1; then SA_PKG="zypper"
        else echo "Gerenciador de pacotes não encontrado."; exit 1
        fi
        PKG="$SA_PKG"
    fi

    _ARG_DRY=false
    _ARG_FIX=false

    for arg in "$@"; do
        case "$arg" in
            --dry-run)     _ARG_DRY=true ;;
            --apply-fixes) _ARG_FIX=true ;;
            --help|-h)
                cat <<EOF
Uso: $0 [--dry-run] [--apply-fixes]

  --dry-run      Simula sem executar alterações
  --apply-fixes  Aplica correções com pinning de versão segura

Sem argumentos: somente auditoria + relatório
EOF
                exit 0 ;;
        esac
    done

    sa_run_audit "$_ARG_DRY" "$_ARG_FIX"
fi
