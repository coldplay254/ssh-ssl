#!/bin/bash
# ==============================================================
#   SSH over TLS - one-command installer + user manager
#   Script by Coldplay
#   Supports: Debian / Ubuntu
# ==============================================================

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; WHITE='\033[1;37m'; NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run as root:  sudo bash install.sh${NC}"
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo -e "${RED}This installer supports Debian/Ubuntu only.${NC}"
    exit 1
fi

clear
echo -e "${CYAN}==============================================${NC}"
echo -e "${WHITE}        SSH over TLS  -  Installer${NC}"
echo -e "${RED}             Script by Coldplay${NC}"
echo -e "${CYAN}==============================================${NC}"
echo

# ---------- packages ----------
echo -e "${YELLOW}[1/8] Installing packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y openssh-server stunnel4 openssl curl procps >/dev/null 2>&1 || {
    echo -e "${RED}Package installation failed.${NC}"
    exit 1
}

# ---------- port ----------
PORT=${TLS_PORT:-443}
busy=$(ss -ltnp 2>/dev/null | awk -v p=":${PORT}\$" '$4 ~ p && $0 !~ /stunnel/')
if [[ -n $busy ]]; then
    echo -e "${YELLOW}Port ${PORT} is already used by another service (nginx?).${NC}"
    read -r -p "Enter another TLS port [8443]: " NEWPORT </dev/tty
    PORT=${NEWPORT:-8443}
fi
mkdir -p /etc/sshtls
echo "$PORT" > /etc/sshtls/port

# ---------- domain ----------
OLD_DOMAIN=$(cat /etc/sshtls/domain 2>/dev/null)
DOMAIN=${TLS_DOMAIN:-}
if [[ -z $DOMAIN ]]; then
    echo
    read -r -p "Enter your domain (e.g. vpn.example.com) [${OLD_DOMAIN:-none}]: " DOMAIN </dev/tty
    DOMAIN=${DOMAIN:-$OLD_DOMAIN}
fi
DOMAIN=$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | tr -d ' ')
[[ $DOMAIN == "none" ]] && DOMAIN=""
if [[ -n $DOMAIN && ! $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    echo -e "${RED}'$DOMAIN' is not a valid domain. Continuing without a domain.${NC}"
    DOMAIN=""
fi
if [[ -n $DOMAIN ]]; then
    echo "$DOMAIN" > /etc/sshtls/domain
    SERVER_IP=$(curl -s -m 5 ifconfig.me 2>/dev/null)
    DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z $DOMAIN_IP ]]; then
        echo -e "${YELLOW}Warning: ${DOMAIN} has no DNS record yet. Point it to this server's IP.${NC}"
    elif [[ -n $SERVER_IP && $DOMAIN_IP != "$SERVER_IP" ]]; then
        echo -e "${YELLOW}Warning: ${DOMAIN} points to ${DOMAIN_IP}, but this server is ${SERVER_IP}.${NC}"
    fi
else
    rm -f /etc/sshtls/domain
fi

# ---------- certificate ----------
echo -e "${YELLOW}[2/8] Preparing TLS certificate...${NC}"
CERT_TYPE="self-signed"
LE_DIR="/etc/letsencrypt/live/${DOMAIN}"

if [[ -n $DOMAIN ]]; then
    # no Let's Encrypt certificate yet: try to get one (needs port 80 free)
    if [[ ! -f $LE_DIR/fullchain.pem ]]; then
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
            echo -e "${YELLOW}Port 80 is busy, so a Let's Encrypt certificate can't be requested automatically.${NC}"
            echo -e "${YELLOW}Using a self-signed certificate. If you already have a certificate for ${DOMAIN}, re-run this installer and it will use it.${NC}"
        else
            echo -e "Requesting a Let's Encrypt certificate for ${WHITE}${DOMAIN}${NC}..."
            apt-get install -y certbot >/dev/null 2>&1
            certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos \
                --register-unsafely-without-email >/tmp/certbot.log 2>&1 \
                || echo -e "${YELLOW}Let's Encrypt failed (see /tmp/certbot.log). Using a self-signed certificate.${NC}"
        fi
    fi

    # use the Let's Encrypt certificate if it exists now
    if [[ -f $LE_DIR/fullchain.pem ]]; then
        cat "$LE_DIR/privkey.pem" "$LE_DIR/fullchain.pem" > /etc/stunnel/sshtls.pem
        chmod 600 /etc/stunnel/sshtls.pem
        # rebuild the stunnel certificate automatically on every renewal
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/sshtls.sh << HOOK
#!/bin/bash
[[ "\$RENEWED_LINEAGE" == */live/${DOMAIN} ]] || exit 0
cat "\$RENEWED_LINEAGE/privkey.pem" "\$RENEWED_LINEAGE/fullchain.pem" > /etc/stunnel/sshtls.pem
chmod 600 /etc/stunnel/sshtls.pem
systemctl restart stunnel4
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/sshtls.sh
        CERT_TYPE="Let's Encrypt"
    fi
fi

# fallback: self-signed certificate (named after the domain when one was given)
if [[ $CERT_TYPE == "self-signed" ]]; then
    if [[ -n $DOMAIN || ! -f /etc/stunnel/sshtls.pem ]]; then
        CN=${DOMAIN:-$(hostname)}
        ADDEXT=()
        [[ -n $DOMAIN ]] && ADDEXT=(-addext "subjectAltName=DNS:${DOMAIN}")
        openssl req -new -x509 -days 3650 -nodes \
            -subj "/CN=${CN}" "${ADDEXT[@]}" \
            -keyout /tmp/sshtls.key -out /tmp/sshtls.crt >/dev/null 2>&1
        cat /tmp/sshtls.key /tmp/sshtls.crt > /etc/stunnel/sshtls.pem
        rm -f /tmp/sshtls.key /tmp/sshtls.crt
        chmod 600 /etc/stunnel/sshtls.pem
    fi
fi

# ---------- stunnel ----------
echo -e "${YELLOW}[3/8] Configuring stunnel on port ${PORT}...${NC}"
cat > /etc/stunnel/sshtls.conf << EOF
pid = /var/run/stunnel4/sshtls.pid
cert = /etc/stunnel/sshtls.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-tls]
accept = ${PORT}
connect = 127.0.0.1:22
EOF
[[ -f /etc/default/stunnel4 ]] && sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4

# ---------- sshd ----------
echo -e "${YELLOW}[4/8] Configuring SSH...${NC}"
# make sure password login is on (also in drop-in files)
sed -i 's/^\s*PasswordAuthentication\s.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^\s*PasswordAuthentication\s.*/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null
grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || sed -i '1i PasswordAuthentication yes' /etc/ssh/sshd_config
# per-user connection limits need pam_limits
grep -q 'pam_limits.so' /etc/pam.d/sshd || echo 'session required pam_limits.so' >> /etc/pam.d/sshd
grep -q '^UsePAM' /etc/ssh/sshd_config || sed -i '1i UsePAM yes' /etc/ssh/sshd_config

touch /etc/sshtls/users.db /etc/security/limits.d/sshtls.conf

# ---------- speed tuning ----------
echo -e "${YELLOW}[5/8] Applying speed tuning (BBR, TCP buffers, SSH)...${NC}"
modprobe tcp_bbr 2>/dev/null
echo tcp_bbr > /etc/modules-load.d/bbr.conf
cat > /etc/sysctl.d/99-sshtls.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_slow_start_after_idle = 0
EOF
sysctl --system >/dev/null 2>&1
# SSH: no compression, no DNS lookups
sed -i '/^\s*Compression\s/d; /^\s*UseDNS\s/d' /etc/ssh/sshd_config
sed -i '1i Compression no\nUseDNS no' /etc/ssh/sshd_config
# drop dead connections within ~45 s so they stop counting against a user's limit
sed -i '/^\s*ClientAliveInterval\s/d; /^\s*ClientAliveCountMax\s/d' /etc/ssh/sshd_config
sed -i '1i ClientAliveInterval 15\nClientAliveCountMax 3' /etc/ssh/sshd_config
BBR_STATE=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

# ---------- udpgw ----------
UDPGW_PORT=${UDPGW_PORT:-7300}
echo -e "${YELLOW}[6/8] Installing udpgw on port ${UDPGW_PORT}...${NC}"
UDPGW_BIN=$(command -v badvpn-udpgw)

build_udpgw() {
    local d
    d=$(mktemp -d) || return 1
    apt-get install -y build-essential cmake wget >/dev/null 2>&1
    (
        cd "$d" || exit 1
        wget -q -O badvpn.tar.gz "https://github.com/ambrop72/badvpn/archive/1.999.130.tar.gz" || exit 1
        tar xzf badvpn.tar.gz || exit 1
        cd badvpn-1.999.130 || exit 1
        mkdir build && cd build || exit 1
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null 2>&1 || exit 1
        make -j"$(nproc)" >/dev/null 2>&1 || exit 1
        install -m 755 udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
    )
    local rc=$?
    rm -rf "$d"
    return $rc
}

if [[ -z $UDPGW_BIN ]]; then
    apt-get install -y badvpn >/dev/null 2>&1
    UDPGW_BIN=$(command -v badvpn-udpgw)
fi
if [[ -z $UDPGW_BIN ]]; then
    echo -e "Building udpgw from source..."
    build_udpgw && UDPGW_BIN=/usr/local/bin/badvpn-udpgw
fi

if [[ -n $UDPGW_BIN && -x $UDPGW_BIN ]]; then
    # listens on localhost only: clients reach it through their SSH tunnel
    cat > /etc/systemd/system/udpgw.service << EOF
[Unit]
Description=BadVPN UDP gateway (udpgw)
After=network.target

[Service]
Type=simple
User=nobody
NoNewPrivileges=true
ExecStart=${UDPGW_BIN} --listen-addr 127.0.0.1:${UDPGW_PORT} --max-clients 1000 --max-connections-for-client 20 --loglevel warning
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable udpgw >/dev/null 2>&1
    systemctl restart udpgw
    echo "$UDPGW_PORT" > /etc/sshtls/udpgw_port
else
    echo -e "${RED}Could not install udpgw. Everything else is installed.${NC}"
    rm -f /etc/sshtls/udpgw_port
fi

# ---------- connection limits ----------
echo -e "${YELLOW}[7/8] Installing connection-limit service...${NC}"
cat > /usr/local/bin/sshtls-connlimit << 'CONN_EOF'
#!/bin/bash
# Enforce the per-user connection limit ("Max users") - Script by Coldplay
#
# sshd's own limit (pam_limits maxlogins) only counts interactive logins, so
# tunnel-only connections slip past it. This service counts the real SSH
# connections of every user in the user list and drops the NEWEST ones above
# that user's limit. The oldest connections are kept.
#
# usage: sshtls-connlimit [users.db]      (default /etc/sshtls/users.db)

DB=${1:-/etc/sshtls/users.db}
INTERVAL=2

enforce_once() {
    local out pid user lim
    # oldest connection first, so everything past the limit is the newest
    out=$(ps -eo user:32=,pid=,args= --sort=-etimes,pid 2>/dev/null | awk -v dbfile="$DB" '
        BEGIN {
            while ((getline line < dbfile) > 0) {
                split(line, f, "|")
                if (f[1] != "" && f[3] ~ /^[0-9]+$/ && f[3] + 0 > 0) limit[f[1]] = f[3] + 0
            }
            close(dbfile)
        }
        $3 ~ /^sshd(-session)?:$/ && ($1 in limit) {
            if (++seen[$1] > limit[$1]) print $2, $1, limit[$1]
        }')
    [[ -z $out ]] && return 0
    while read -r pid user lim; do
        kill -KILL "$pid" 2>/dev/null && echo "dropped an extra connection of '$user' (limit $lim)"
    done <<< "$out"
}

while true; do
    enforce_once
    sleep "$INTERVAL"
done
CONN_EOF
chmod 755 /usr/local/bin/sshtls-connlimit

cat > /etc/systemd/system/sshtls-connlimit.service << EOF
[Unit]
Description=Enforce per-user connection limits for SSH tunnels
After=network.target ssh.service

[Service]
Type=simple
ExecStart=/usr/local/bin/sshtls-connlimit /etc/sshtls/users.db
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sshtls-connlimit >/dev/null 2>&1
systemctl restart sshtls-connlimit

# ---------- menu ----------
echo -e "${YELLOW}[8/8] Installing menu...${NC}"
cat > /usr/local/bin/menu << 'MENU_EOF'
#!/bin/bash
# SSH over TLS user manager - Script by Coldplay

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; WHITE='\033[1;37m'; NC='\033[0m'

DB=/etc/sshtls/users.db
LIMITS=/etc/security/limits.d/sshtls.conf
BANNER=/etc/sshtls/banner
PORT=$(cat /etc/sshtls/port 2>/dev/null || echo 443)
DOMAIN=$(cat /etc/sshtls/domain 2>/dev/null)
UDPGW=$(cat /etc/sshtls/udpgw_port 2>/dev/null)

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root.${NC}"
    exit 1
fi
touch "$DB" "$LIMITS"

pause() { echo; read -r -p " Press Enter to continue..."; }

# usernames: 3-32 chars, letters (any case), digits, _ and -, must start with a letter or _
valid_username() {
    local LC_ALL=C
    [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_-]{2,31}$ ]]
}

reload_ssh() {
    sshd -t 2>/dev/null && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; }
}

count_online() { ps -u "$1" -o args= 2>/dev/null | grep -c '^sshd:'; }

set_limit() {
    sed -i "/^$1[[:space:]]/d" "$LIMITS"
    echo "$1 hard maxlogins $2" >> "$LIMITS"
}

db_set() {   # db_set <user> <field-number> <value>
    awk -F'|' -v u="$1" -v f="$2" -v v="$3" 'BEGIN{OFS="|"} $1==u{$f=v} {print}' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
}

choose_user() {
    mapfile -t U < <(cut -d'|' -f1 "$DB" | grep .)
    if [[ ${#U[@]} -eq 0 ]]; then
        echo -e " ${RED}No users yet.${NC}"
        return 1
    fi
    local i=1 x
    for x in "${U[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $x"
        i=$((i + 1))
    done
    echo
    read -r -p " Select user number: " n
    if [[ ! $n =~ ^[0-9]+$ || $n -lt 1 || $n -gt ${#U[@]} ]]; then
        echo -e " ${RED}Invalid choice.${NC}"
        return 1
    fi
    SEL=${U[$((n - 1))]}
}

header() {
    clear
    local total=0 users u
    while IFS='|' read -r u _ _; do
        [[ -z $u ]] && continue
        total=$((total + $(count_online "$u")))
    done < "$DB"
    users=$(grep -c . "$DB")
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}          SSH over TLS  -  User Manager     ${CYAN}║${NC}"
    echo -e "${CYAN}║${RED}             Script by Coldplay             ${CYAN}║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════╣${NC}"
    printf "${CYAN}║${NC} TLS port: ${GREEN}%-6s${NC} Users: ${GREEN}%-4s${NC} Online: ${GREEN}%-4s${NC}  ${CYAN}║${NC}\n" "$PORT" "$users" "$total"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo
}

add_user() {
    header
    echo -e " ${YELLOW}--- Add user ---${NC}"
    echo
    read -r -p " Username          : " u
    if ! valid_username "$u"; then
        echo -e " ${RED}Invalid username (3-32 chars: letters A-Z a-z, 0-9, _ -).${NC}"; pause; return
    fi
    if id "$u" &>/dev/null; then
        echo -e " ${RED}User already exists.${NC}"; pause; return
    fi
    IFS= read -r -s -p " Password          : " p; echo
    if [[ -z $p ]]; then
        echo -e " ${RED}Password cannot be empty.${NC}"; pause; return
    fi
    read -r -p " Days (expiry)    : " d
    if [[ ! $d =~ ^[0-9]+$ || $d -lt 1 ]]; then
        echo -e " ${RED}Days must be a number above 0.${NC}"; pause; return
    fi
    read -r -p " Max users        : " m
    if [[ ! $m =~ ^[0-9]+$ || $m -lt 1 ]]; then
        echo -e " ${RED}Max users must be a number above 0.${NC}"; pause; return
    fi

    local exp ip
    exp=$(date -d "+$d days" +%Y-%m-%d)
    if ! useradd -M -s /bin/false -e "$exp" "$u" 2>/dev/null \
       && ! useradd --badname -M -s /bin/false -e "$exp" "$u"; then
        echo -e " ${RED}Could not create user.${NC}"; pause; return
    fi
    printf '%s:%s\n' "$u" "$p" | chpasswd
    set_limit "$u" "$m"
    sed -i "/^$u|/d" "$DB"
    echo "$u|$exp|$m" >> "$DB"

    ip=$(curl -s -m 3 ifconfig.me 2>/dev/null)
    [[ -z $ip ]] && ip=$(hostname -I | awk '{print $1}')
    echo
    echo -e " ${GREEN}User created successfully${NC}"
    echo -e " ${CYAN}------------------------------${NC}"
    echo -e " Host      : ${WHITE}${DOMAIN:-$ip}${NC}"
    [[ -n $DOMAIN ]] && echo -e " Server IP : ${WHITE}$ip${NC}"
    echo -e " TLS port  : ${WHITE}$PORT${NC}"
    [[ -n $UDPGW ]] && echo -e " UDPGW     : ${WHITE}127.0.0.1:$UDPGW${NC}"
    echo -e " Username  : ${WHITE}$u${NC}"
    printf ' Password  : %b%s%b\n' "$WHITE" "$p" "$NC"
    echo -e " Expires   : ${WHITE}$exp${NC}"
    echo -e " Max users : ${WHITE}$m${NC}"
    echo -e " ${CYAN}------------------------------${NC}"
    pause
}

delete_user() {
    header
    echo -e " ${YELLOW}--- Delete user ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " Delete '$SEL'? [y/N]: " c
    if [[ $c =~ ^[Yy]$ ]]; then
        pkill -KILL -u "$SEL" 2>/dev/null
        userdel "$SEL" 2>/dev/null
        sed -i "/^$SEL[[:space:]]/d" "$LIMITS"
        sed -i "/^$SEL|/d" "$DB"
        echo -e " ${GREEN}User '$SEL' deleted.${NC}"
    else
        echo -e " Cancelled."
    fi
    pause
}

list_users() {
    header
    echo -e " ${YELLOW}--- All users ---${NC}"
    echo
    printf " ${WHITE}%-16s %-12s %-10s %-8s${NC}\n" "USERNAME" "EXPIRES" "DAYS LEFT" "MAX"
    echo -e " ${CYAN}--------------------------------------------------${NC}"
    local u exp m left col
    while IFS='|' read -r u exp m; do
        [[ -z $u ]] && continue
        left=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
        col=$GREEN
        (( left <= 3 )) && col=$YELLOW
        (( left < 0 )) && { col=$RED; left="expired"; }
        printf " %-16s %-12s ${col}%-10s${NC} %-8s\n" "$u" "$exp" "$left" "$m"
    done < "$DB"
    pause
}

online_users() {
    header
    echo -e " ${YELLOW}--- Online users ---${NC}"
    echo
    printf " ${WHITE}%-16s %-12s %-8s${NC}\n" "USERNAME" "CONNECTIONS" "LIMIT"
    echo -e " ${CYAN}-------------------------------------${NC}"
    local u m c any=0
    while IFS='|' read -r u _ m; do
        [[ -z $u ]] && continue
        c=$(count_online "$u")
        if (( c > 0 )); then
            printf " %-16s ${GREEN}%-12s${NC} %-8s\n" "$u" "$c" "$m"
            any=1
        fi
    done < "$DB"
    (( any == 0 )) && echo -e " ${YELLOW}Nobody is online right now.${NC}"
    pause
}

change_expiry() {
    header
    echo -e " ${YELLOW}--- Change expiry ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " New expiry in days from today: " d
    if [[ ! $d =~ ^[0-9]+$ || $d -lt 1 ]]; then
        echo -e " ${RED}Days must be a number above 0.${NC}"; pause; return
    fi
    local exp
    exp=$(date -d "+$d days" +%Y-%m-%d)
    usermod -e "$exp" "$SEL"
    db_set "$SEL" 2 "$exp"
    echo -e " ${GREEN}'$SEL' now expires on $exp.${NC}"
    pause
}

change_limit() {
    header
    echo -e " ${YELLOW}--- Change connection limit ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " New max users (connections) for '$SEL': " m
    if [[ ! $m =~ ^[0-9]+$ || $m -lt 1 ]]; then
        echo -e " ${RED}Must be a number above 0.${NC}"; pause; return
    fi
    set_limit "$SEL" "$m"
    db_set "$SEL" 3 "$m"
    echo -e " ${GREEN}'$SEL' can now have $m connection(s) (enforced within a few seconds).${NC}"
    pause
}

set_banner() {
    header
    echo -e " ${YELLOW}--- Login banner ---${NC}"
    echo
    echo -e "  ${GREEN}1)${NC} Set / change banner"
    echo -e "  ${GREEN}2)${NC} Remove banner"
    echo
    read -r -p " Select: " b
    case $b in
        1)
            echo -e " Type the banner text. Use ${WHITE}\\\\n${NC} for a new line."
            read -r -p " > " text
            if [[ -z $text ]]; then
                echo -e " ${RED}Banner cannot be empty.${NC}"; pause; return
            fi
            printf '%b\n' "$text" > "$BANNER"
            sed -i '/^\s*#\?\s*Banner\s/d' /etc/ssh/sshd_config
            sed -i "1i Banner $BANNER" /etc/ssh/sshd_config
            reload_ssh
            echo -e " ${GREEN}Banner saved.${NC}"
            ;;
        2)
            rm -f "$BANNER"
            sed -i '/^\s*Banner\s/d' /etc/ssh/sshd_config
            reload_ssh
            echo -e " ${GREEN}Banner removed.${NC}"
            ;;
        *) echo -e " ${RED}Invalid choice.${NC}" ;;
    esac
    pause
}

remove_expired() {
    header
    echo -e " ${YELLOW}--- Remove expired users ---${NC}"
    echo
    local today u exp m n=0
    today=$(date +%Y-%m-%d)
    while IFS='|' read -r u exp m; do
        [[ -z $u ]] && continue
        if [[ $exp < $today ]]; then
            pkill -KILL -u "$u" 2>/dev/null
            userdel "$u" 2>/dev/null
            sed -i "/^$u[[:space:]]/d" "$LIMITS"
            sed -i "/^$u|/d" "$DB"
            echo -e " Removed ${RED}$u${NC} (expired $exp)"
            n=$((n + 1))
        fi
    done < <(cat "$DB")
    echo
    echo -e " ${GREEN}$n expired user(s) removed.${NC}"
    pause
}

service_status() {
    header
    echo -e " ${YELLOW}--- Services ---${NC}"
    echo
    local s
    for s in stunnel4 ssh udpgw sshtls-connlimit; do
        if systemctl is-active --quiet "$s" 2>/dev/null || { [[ $s == ssh ]] && systemctl is-active --quiet sshd 2>/dev/null; }; then
            echo -e " $s : ${GREEN}running${NC}"
        else
            echo -e " $s : ${RED}stopped${NC}"
        fi
    done
    echo
    read -r -p " Restart stunnel and udpgw now? [y/N]: " c
    if [[ $c =~ ^[Yy]$ ]]; then
        systemctl restart stunnel4 && echo -e " ${GREEN}stunnel restarted.${NC}"
        systemctl restart udpgw 2>/dev/null && echo -e " ${GREEN}udpgw restarted.${NC}"
        systemctl restart sshtls-connlimit 2>/dev/null && echo -e " ${GREEN}sshtls-connlimit restarted.${NC}"
    fi
    pause
}

while true; do
    header
    echo -e "  ${GREEN}1)${NC} Add user"
    echo -e "  ${GREEN}2)${NC} Delete user"
    echo -e "  ${GREEN}3)${NC} List users"
    echo -e "  ${GREEN}4)${NC} Online users"
    echo -e "  ${GREEN}5)${NC} Change expiry"
    echo -e "  ${GREEN}6)${NC} Change connection limit"
    echo -e "  ${GREEN}7)${NC} Login banner"
    echo -e "  ${GREEN}8)${NC} Remove expired users"
    echo -e "  ${GREEN}9)${NC} Service status / restart"
    echo -e "  ${RED}0)${NC} Exit"
    echo
    read -r -p " Select option: " opt
    case $opt in
        1) add_user ;;
        2) delete_user ;;
        3) list_users ;;
        4) online_users ;;
        5) change_expiry ;;
        6) change_limit ;;
        7) set_banner ;;
        8) remove_expired ;;
        9) service_status ;;
        0) clear; exit 0 ;;
        *) echo -e " ${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
MENU_EOF
chmod +x /usr/local/bin/menu

# ---------- start services ----------
if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
fi
systemctl enable stunnel4 >/dev/null 2>&1
systemctl restart stunnel4

echo
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}  Installation complete${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e " SSH over TLS is listening on port ${WHITE}${PORT}${NC}"
[[ -n $DOMAIN ]] && echo -e " Domain      : ${WHITE}${DOMAIN}${NC}"
echo -e " Certificate : ${WHITE}${CERT_TYPE}${NC}"
if systemctl is-active --quiet udpgw; then
    echo -e " UDPGW       : ${WHITE}127.0.0.1:${UDPGW_PORT}${NC} (reach it through the SSH tunnel)"
else
    echo -e " UDPGW       : ${RED}not running${NC}"
fi
echo -e " TCP control : ${WHITE}${BBR_STATE:-unknown}${NC}"
echo -e " Conn. limits : ${WHITE}enforced per user${NC}"
echo -e " Type ${WHITE}menu${NC} to open the user manager"
echo -e "${RED}                         Script by Coldplay${NC}"
echo
