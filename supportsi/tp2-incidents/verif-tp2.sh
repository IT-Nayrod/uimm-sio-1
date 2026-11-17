#!/bin/bash
# ------------------------------------------------------------------
# BTS SIO 1, Support SI, TP2 : incidents automatiques et API de GLPI
# Script de vérification, à lancer sur Serveur-Cyber :
#
#   sudo ./verif-tp2.sh             verdict global
#   sudo ./verif-tp2.sh --details   détail de chaque contrôle et quoi corriger
#
# Le script ne modifie rien : il lit la base de GLPI.
# ------------------------------------------------------------------

GLPI_DIR="/var/www/glpi"

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
total=0; reussis=0; lignes=()

verifier() {
    total=$((total + 1))
    if "$3" >/dev/null 2>&1; then
        reussis=$((reussis + 1))
        lignes+=("${VERT}[OK]${RAZ}       $1")
    else
        lignes+=("${ROUGE}[MANQUANT]${RAZ} $1"$'\n'"           -> $2")
    fi
}
section() { lignes+=("" "${GRAS}$1${RAZ}"); }

BASE=$(sed -n "s/.*dbdefault *= *'\([^']*\)'.*/\1/p" "$GLPI_DIR/config/config_db.php" 2>/dev/null)
[ -z "$BASE" ] && BASE="glpi"
sql()    { mysql --default-character-set=utf8mb4 -N -B "$BASE" -e "$1" 2>/dev/null; }
nombre() { local n; n=$(sql "$1"); [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0; }
au_moins() { [ "$(nombre "$2")" -ge "$1" ]; }

if [ -z "$(sql "SELECT 1")" ]; then
    echo "${ROUGE}Base de GLPI introuvable : lance ce script sur Serveur-Cyber, après le TP Découverte.${RAZ}"
    exit 2
fi

# ---------- Contrôles ----------

poste_present() {
    # $1 nom du poste : ordinateur, ou équipement réseau si le TP SNMP a déjà été fait
    au_moins 1 "SELECT COUNT(*) FROM glpi_computers WHERE is_deleted=0 AND is_template=0 AND name LIKE '$1%'" ||
    au_moins 1 "SELECT COUNT(*) FROM glpi_networkequipments WHERE is_deleted=0 AND name LIKE '$1%'"
}
t_client2() { poste_present client2; }
t_client3() { poste_present client3; }

t_fields()  { au_moins 1 "SELECT COUNT(*) FROM glpi_plugins WHERE directory='fields' AND state=1"; }
t_champ_ticket() {
    au_moins 1 "SELECT COUNT(*) FROM glpi_plugin_fields_containers c
                JOIN glpi_plugin_fields_fields f ON f.plugin_fields_containers_id=c.id
                WHERE c.is_active=1 AND c.itemtypes LIKE '%Ticket%'"
}

t_api()        { [ "$(sql "SELECT value FROM glpi_configs WHERE context='core' AND name='enable_api'")" = "1" ]; }
t_api_jeton()  { [ "$(sql "SELECT value FROM glpi_configs WHERE context='core' AND name='enable_api_login_external_token'")" = "1" ]; }
t_client_api() { au_moins 1 "SELECT COUNT(*) FROM glpi_apiclients WHERE is_active=1 AND app_token IS NOT NULL AND app_token<>''"; }
t_automate()   { au_moins 1 "SELECT COUNT(*) FROM glpi_users WHERE name='automate' AND is_active=1 AND is_deleted=0 AND api_token IS NOT NULL AND api_token<>''"; }

t_ticket_client2() { au_moins 1 "SELECT COUNT(*) FROM glpi_tickets WHERE is_deleted=0 AND name LIKE '[client2]%'"; }
t_ticket_client3() { au_moins 1 "SELECT COUNT(*) FROM glpi_tickets WHERE is_deleted=0 AND name LIKE '[client3]%'"; }

t_categories() { au_moins 2 "SELECT COUNT(*) FROM glpi_itilcategories"; }
t_ticket_resolu() {
    au_moins 1 "SELECT COUNT(*) FROM glpi_tickets t
                WHERE t.is_deleted=0 AND t.status IN (5,6) AND t.itilcategories_id>0
                  AND EXISTS (SELECT 1 FROM glpi_itilsolutions s WHERE s.itemtype='Ticket' AND s.items_id=t.id)"
}
t_ticket_attribue() {
    au_moins 1 "SELECT COUNT(*) FROM glpi_tickets t WHERE t.is_deleted=0 AND (
                  EXISTS (SELECT 1 FROM glpi_tickets_users u WHERE u.tickets_id=t.id AND u.type=2)
               OR EXISTS (SELECT 1 FROM glpi_groups_tickets g WHERE g.tickets_id=t.id AND g.type=2))"
}
t_suivi()  { au_moins 1 "SELECT COUNT(*) FROM glpi_itilfollowups WHERE itemtype='Ticket'"; }
t_kb()     { au_moins 1 "SELECT COUNT(*) FROM glpi_knowbaseitems"; }

# ---------- Exécution ----------

echo "${GRAS}Vérification du TP2 : incidents automatiques et API ($(hostname))${RAZ}"

section "Nouveaux postes"
verifier "client2 inventorié dans GLPI" \
    "sur client2 : nom de machine client2, agent réinitialisé, puis sudo glpi-agent --force (Partie 1)" t_client2
verifier "client3 inventorié dans GLPI" \
    "sur client3 : nom de machine client3, agent réinitialisé, puis sudo glpi-agent --force (Partie 1)" t_client3

section "Plugin et champ personnalisé"
verifier "Plugin Fields installé et activé" \
    "Configuration, Plugins : installe puis active Fields, ou installation manuelle 1.24.7 (Partie 2)" t_fields
verifier "Bloc de champs actif sur les tickets, avec au moins un champ" \
    "Configuration, Champs supplémentaires : bloc associé aux tickets et champ Origine (Partie 2)" t_champ_ticket

section "API REST"
verifier "API REST activée" \
    "Configuration, Générale, onglet API : active l'API REST (Partie 3)" t_api
verifier "Authentification par jeton externe activée" \
    "même onglet API : active la connexion avec un jeton externe (Partie 3)" t_api_jeton
verifier "Client API actif avec un jeton d'application" \
    "onglet API : ajoute un client API et génère son jeton d'application (Partie 3)" t_client_api
verifier "Compte de service automate actif, avec sa clé d'accès distant" \
    "Administration, Utilisateurs : compte automate, puis génère sa clé d'accès distant (Partie 3)" t_automate

section "Tickets ouverts par les scripts"
verifier "Au moins un ticket ouvert automatiquement par client2" \
    "sur client2, dans ~/uimm-sio-1/supportsi/tp2-incidents : ./incident-disque-plein.sh (Partie 4)" t_ticket_client2
verifier "Au moins un ticket ouvert automatiquement par client3" \
    "sur client3, dans ~/uimm-sio-1/supportsi/tp2-incidents : ./incident-service-arrete.sh (Partie 4)" t_ticket_client3

section "Traitement des tickets"
verifier "Au moins deux catégories ITIL" \
    "Configuration, Intitulés, Catégories ITIL (Partie 5)" t_categories
verifier "Un ticket résolu, avec catégorie et solution" \
    "ouvre un ticket, donne-lui une catégorie, puis ajoute une solution (Partie 5)" t_ticket_resolu
verifier "Un ticket attribué à un technicien ou à un groupe" \
    "dans le ticket, champ Attribué à (Partie 5)" t_ticket_attribue
verifier "Un suivi ajouté sur un ticket" \
    "dans le ticket, bouton Suivi (Partie 5)" t_suivi
verifier "Au moins un article dans la base de connaissances" \
    "depuis un ticket résolu, crée un article de base de connaissances (Partie 5)" t_kb

# ---------- Verdict ----------
if [ "$DETAILS" -eq 1 ]; then printf '%s\n' "${lignes[@]}"; echo; fi

if [ "$reussis" -eq "$total" ]; then
    echo "${VERT}${GRAS}Tout est en place (${reussis}/${total}).${RAZ}"
    exit 0
else
    echo "${ROUGE}${GRAS}${reussis}/${total} contrôles validés : $((total - reussis)) élément(s) manquant(s).${RAZ}"
    [ "$DETAILS" -eq 0 ] && echo "Relance avec : sudo ./verif-tp2.sh --details pour savoir quoi corriger."
    exit 1
fi
