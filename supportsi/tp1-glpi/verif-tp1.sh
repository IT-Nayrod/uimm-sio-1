#!/bin/bash
# ------------------------------------------------------------------
# BTS SIO 1, Support SI, TP Découverte : GLPI sur Serveur-Cyber
# Script de vérification, à lancer sur Serveur-Cyber :
#
#   sudo ./verif-tp1.sh             verdict global
#   sudo ./verif-tp1.sh --details   détail de chaque contrôle et quoi corriger
#
# Le script ne modifie rien : il lit la configuration du serveur
# et la base de GLPI.
# ------------------------------------------------------------------

GLPI_DIR="/var/www/glpi"
PORT_GLPI="8080"

DETAILS=0
case "$1" in
    -d|-v|--details) DETAILS=1 ;;
    "") ;;
    *) echo "Utilisation : sudo $0 [--details]"; exit 2 ;;
esac

if [ "$EUID" -ne 0 ]; then
    echo "Lance ce script avec sudo : sudo $0 $*"
    exit 2
fi

VERT=$'\e[32m'; ROUGE=$'\e[31m'; JAUNE=$'\e[33m'; GRAS=$'\e[1m'; RAZ=$'\e[0m'
total=0
reussis=0
lignes=()

verifier() {
    # $1 libellé, $2 conseil en cas d'échec, $3 fonction de test
    total=$((total + 1))
    if "$3" >/dev/null 2>&1; then
        reussis=$((reussis + 1))
        lignes+=("${VERT}[OK]${RAZ}       $1")
    else
        lignes+=("${ROUGE}[MANQUANT]${RAZ} $1"$'\n'"           -> $2")
    fi
}

information() {
    lignes+=("${JAUNE}[INFO]${RAZ}     $1")
}

section() {
    lignes+=("" "${GRAS}$1${RAZ}")
}

# ---------- Outils ----------

# Base de GLPI : lue dans le fichier de configuration créé par l'assistant
BASE=$(sed -n "s/.*dbdefault *= *'\([^']*\)'.*/\1/p" "$GLPI_DIR/config/config_db.php" 2>/dev/null)
[ -z "$BASE" ] && BASE="glpi"

sql() {
    mysql -N -B "$BASE" -e "$1" 2>/dev/null
}

nombre() {
    # Renvoie un entier, 0 si la requête échoue
    local n
    n=$(sql "$1")
    [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# Fichier de site Nginx qui sert GLPI sur le port 8080
SITE_GLPI=$(grep -lE "^[[:space:]]*listen[[:space:]]+([0-9.]+:)?${PORT_GLPI}[[:space:];]" /etc/nginx/sites-enabled/* 2>/dev/null | head -n 1)

# Version de PHP utilisée par le site GLPI (d'après fastcgi_pass)
PHPV=$(grep -ohE 'php[0-9]+\.[0-9]+-fpm\.sock' "${SITE_GLPI:-/dev/null}" 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+')
[ -z "$PHPV" ] && PHPV=$(ls /etc/php 2>/dev/null | sort -V | tail -n 1)

# ---------- Sécurisation des TP de cybersécurité ----------

t_root_ssh()   { sshd -T 2>/dev/null | grep -qx 'permitrootlogin no'; }
t_mdp_ssh()    { sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; }
t_cles_ssh()   { sshd -T 2>/dev/null | grep -i '^authorizedkeysfile' | grep -q '/etc/ssh/authorized_keys/%u'; }
t_fail2ban()   { systemctl is-active --quiet fail2ban && fail2ban-client status sshd; }
t_ufw_actif()  { ufw status | grep -q 'Status: active'; }

# ---------- Services web ----------

t_nginx_ok()   { systemctl is-active --quiet nginx && nginx -t; }
t_securelab()  { curl -s --max-time 5 http://127.0.0.1/ | grep -q 'SecureLab'; }

t_site_glpi() {
    [ -n "$SITE_GLPI" ] || return 1
    grep -qE "^[[:space:]]*root[[:space:]]+${GLPI_DIR}/public;" "$SITE_GLPI"
}

t_pas_default_server() {
    [ -n "$SITE_GLPI" ] || return 1
    ! grep -qE 'listen[^;]*80[^0-9][^;]*default_server' "$SITE_GLPI"
}

t_socket_php() {
    [ -n "$SITE_GLPI" ] || return 1
    local s
    s=$(grep -ohE 'unix:[^;]+' "$SITE_GLPI" | head -n 1 | cut -d: -f2)
    [ -S "$s" ]
}

t_glpi_repond() {
    local code
    code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT_GLPI}/")
    [[ "$code" =~ ^(200|30[0-9])$ ]]
}

t_ufw_8080() {
    local regles
    regles=$(ufw status | grep -E "^${PORT_GLPI}(/tcp)?[[:space:]]+ALLOW")
    [ -n "$regles" ] || return 1
    ! echo "$regles" | grep -q 'Anywhere'
}

t_cookie_httponly() {
    grep -Eiq '^[[:space:]]*session\.cookie_httponly[[:space:]]*=[[:space:]]*(On|1)[[:space:]]*$' "/etc/php/${PHPV}/fpm/php.ini"
}

# ---------- Base de données ----------

t_mariadb_local() {
    systemctl is-active --quiet mariadb || return 1
    local adresses
    adresses=$(ss -tlnH '( sport = :3306 )' | awk '{print $4}')
    [ -n "$adresses" ] || return 1
    ! echo "$adresses" | grep -vqE '^(127\.0\.0\.1|\[::1\]|localhost):3306$'
}

t_glpi_installe() {
    [ -f "$GLPI_DIR/config/config_db.php" ] && [ "$(nombre "SELECT COUNT(*) FROM glpi_users")" -gt 0 ]
}

t_install_supprime() { [ ! -e "$GLPI_DIR/install/install.php" ]; }

mot_de_passe_par_defaut() {
    # $1 compte, $2 mot de passe d'origine ; vrai si le compte actif a encore ce mot de passe
    local h
    h=$(sql "SELECT password FROM glpi_users WHERE name='$1' AND is_active=1 AND is_deleted=0 LIMIT 1")
    [ -n "$h" ] || return 1
    H="$h" P="$2" php -r 'exit(password_verify(getenv("P"), getenv("H")) ? 0 : 1);'
}

COMPTES_PAR_DEFAUT=""
for c in glpi:glpi tech:tech normal:normal post-only:postonly; do
    mot_de_passe_par_defaut "${c%%:*}" "${c#*:}" && COMPTES_PAR_DEFAUT="$COMPTES_PAR_DEFAUT ${c%%:*}"
done

t_mdp_glpi() { [ -z "$COMPTES_PAR_DEFAUT" ] && t_glpi_installe; }

# ---------- Inventaire et exploration ----------

t_inventaire_active() {
    [ "$(sql "SELECT value FROM glpi_configs WHERE context='inventory' AND name='enabled_inventory'")" = "1" ]
}

t_agent_serveur() {
    command -v glpi-agent || return 1
    cat /etc/glpi-agent/agent.cfg /etc/glpi-agent/conf.d/*.cfg 2>/dev/null \
        | grep -E '^[[:space:]]*server[[:space:]]*=' | grep -q ":${PORT_GLPI}/front/inventory.php"
}

t_deux_ordinateurs() {
    [ "$(nombre "SELECT COUNT(*) FROM glpi_computers WHERE is_deleted=0 AND is_template=0")" -ge 2 ]
}

t_utilisateur_poste() {
    [ "$(nombre "SELECT COUNT(*) FROM glpi_computers WHERE is_deleted=0 AND is_template=0 AND users_id>0")" -ge 1 ]
}

t_imprimante() {
    [ "$(nombre "SELECT COUNT(*) FROM glpi_printers p
                 JOIN glpi_infocoms i ON i.itemtype='Printer' AND i.items_id=p.id
                 WHERE p.is_deleted=0 AND p.is_template=0 AND p.states_id>0
                   AND i.buy_date IS NOT NULL AND i.warranty_duration>0 AND i.value>0")" -ge 1 ]
}

t_ticket() {
    [ "$(nombre "SELECT COUNT(*) FROM glpi_tickets WHERE is_deleted=0")" -ge 1 ]
}

# ---------- Exécution ----------

echo "${GRAS}Vérification du TP Découverte GLPI ($(hostname))${RAZ}"

VERSION_GLPI=$(sql "SELECT value FROM glpi_configs WHERE context='core' AND name='version'")
information "Système : $(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME"), PHP ${PHPV:-non trouvé}, GLPI ${VERSION_GLPI:-non installé}"

section "Sécurisation des TP de cybersécurité (ne doit pas avoir bougé)"
verifier "SSH : connexion directe de root interdite" \
    "PermitRootLogin no dans /etc/ssh/sshd_config, puis sudo systemctl restart ssh (TP1 cyber)" t_root_ssh
verifier "SSH : authentification par mot de passe désactivée" \
    "PasswordAuthentication no dans /etc/ssh/sshd_config (et dans /etc/ssh/sshd_config.d/*.conf, qui passent en premier), puis sudo systemctl restart ssh (TP6 cyber)" t_mdp_ssh
verifier "SSH : clés centralisées dans /etc/ssh/authorized_keys/%u" \
    "AuthorizedKeysFile /etc/ssh/authorized_keys/%u dans /etc/ssh/sshd_config (TP4 cyber)" t_cles_ssh
verifier "Fail2ban actif avec la prison sshd" \
    "sudo systemctl enable --now fail2ban, puis sudo fail2ban-client status sshd (TP1 cyber)" t_fail2ban
verifier "Pare-feu UFW actif" \
    "sudo ufw enable (TP1 cyber)" t_ufw_actif

section "Serveur web"
verifier "Nginx actif et configuration valide (nginx -t)" \
    "sudo nginx -t indique le fichier et la ligne en erreur" t_nginx_ok
verifier "Le site SecureLab répond toujours sur le port 80" \
    "le lien securelab doit rester dans /etc/nginx/sites-enabled/ (étape 2)" t_securelab
verifier "Site GLPI activé sur le port ${PORT_GLPI}, qui n'expose que ${GLPI_DIR}/public" \
    "crée /etc/nginx/sites-available/glpi (listen ${PORT_GLPI}, root ${GLPI_DIR}/public) et son lien dans sites-enabled (étape 2)" t_site_glpi
verifier "Le site GLPI ne prend pas la place de SecureLab (pas de default_server sur le port 80)" \
    "le site GLPI écoute sur ${PORT_GLPI}, sans default_server (étape 2)" t_pas_default_server
verifier "fastcgi_pass pointe vers la bonne version de PHP" \
    "ls /run/php/ donne le nom exact du fichier .sock à mettre dans le site GLPI (étape 2)" t_socket_php
verifier "GLPI répond sur http://127.0.0.1:${PORT_GLPI}" \
    "vérifie sudo nginx -t, puis systemctl status nginx php${PHPV}-fpm" t_glpi_repond
verifier "Port ${PORT_GLPI} ouvert dans UFW au seul réseau du labo (pas à Anywhere)" \
    "sudo ufw allow from 192.168.50.0/24 to any port ${PORT_GLPI} proto tcp ; supprime une éventuelle règle ouverte à tous avec sudo ufw delete allow ${PORT_GLPI} (étape 2)" t_ufw_8080
verifier "Cookies de session protégés (session.cookie_httponly = On)" \
    "dans /etc/php/${PHPV}/fpm/php.ini, puis sudo systemctl restart php${PHPV}-fpm (étape 2)" t_cookie_httponly

section "Base de données et installation de GLPI"
verifier "MariaDB actif et joignable uniquement depuis le serveur (127.0.0.1)" \
    "MariaDB ne doit pas écouter sur 0.0.0.0 : vérifie bind-address dans /etc/mysql/mariadb.conf.d/50-server.cnf (étape 1)" t_mariadb_local
verifier "GLPI installé (assistant terminé, base remplie)" \
    "termine l'assistant sur http://192.168.50.10:${PORT_GLPI} (étape 3)" t_glpi_installe
verifier "Fichier install/install.php supprimé" \
    "sudo rm ${GLPI_DIR}/install/install.php (étape 3)" t_install_supprime
verifier "Mots de passe des comptes par défaut changés" \
    "comptes encore avec leur mot de passe d'origine :${COMPTES_PAR_DEFAUT:- aucun} ; Administration, Utilisateurs (étape 3)" t_mdp_glpi

section "Inventaire et exploration du parc"
verifier "Inventaire activé dans GLPI" \
    "Administration, Inventaire : coche Activer l'inventaire (étape 4)" t_inventaire_active
verifier "Agent GLPI installé sur le serveur, configuré vers le port ${PORT_GLPI}" \
    "server = http://192.168.50.10:${PORT_GLPI}/front/inventory.php dans /etc/glpi-agent/conf.d/local.cfg (étape 4)" t_agent_serveur
verifier "Au moins deux ordinateurs inventoriés (le client et le serveur)" \
    "sudo glpi-agent --force sur Client-Cyber et sur Serveur-Cyber (étape 4)" t_deux_ordinateurs
verifier "Un utilisateur rattaché à un poste" \
    "fiche de Client-Cyber, champ Utilisateur (étape 5, mission 3)" t_utilisateur_poste
verifier "Imprimante avec statut, date d'achat, garantie et valeur" \
    "Parc, Imprimantes : statut, puis onglet Gestion (étape 5, missions 2, 4 et 5)" t_imprimante
verifier "Au moins un ticket créé" \
    "connecte-toi avec le compte normal et crée le ticket de l'étape 6" t_ticket

# ---------- Verdict ----------
if [ "$DETAILS" -eq 1 ]; then
    printf '%s\n' "${lignes[@]}"
    echo
fi

if [ "$reussis" -eq "$total" ]; then
    echo "${VERT}${GRAS}Tout est en place (${reussis}/${total}).${RAZ}"
    exit 0
else
    manquants=$((total - reussis))
    echo "${ROUGE}${GRAS}${reussis}/${total} contrôles validés : ${manquants} élément(s) manquant(s).${RAZ}"
    [ "$DETAILS" -eq 0 ] && echo "Relance avec : sudo ./verif-tp1.sh --details pour savoir quoi corriger."
    exit 1
fi
