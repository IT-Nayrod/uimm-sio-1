#!/bin/bash
# ------------------------------------------------------------------
# BTS SIO 1, Support SI, TP3 : catalogue de services, formulaires et demandes
# Script de vérification, à lancer sur Serveur-Cyber :
#
#   sudo ./verif-tp3.sh             verdict global
#   sudo ./verif-tp3.sh --details   détail de chaque contrôle et quoi corriger
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

VERT=$'\e[32m'; ROUGE=$'\e[31m'; GRAS=$'\e[1m'; RAZ=$'\e[0m'
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

# Identifiants utiles (0 si absents)
id_de() { local i; i=$(sql "$1" | head -n 1); [[ "$i" =~ ^[0-9]+$ ]] && echo "$i" || echo 0; }
MARIE=$(id_de "SELECT id FROM glpi_users WHERE name='marie.demandeur' AND is_deleted=0")
PAUL=$(id_de "SELECT id FROM glpi_users WHERE name='paul.resp' AND is_deleted=0")
TECH=$(id_de "SELECT id FROM glpi_users WHERE name='tech.n1' AND is_deleted=0")
N1=$(id_de "SELECT id FROM glpi_groups WHERE name='Support N1'")
N2=$(id_de "SELECT id FROM glpi_groups WHERE name='Support N2'")
SLA=$(id_de "SELECT id FROM glpi_slas WHERE type=0 AND number_time=8 AND definition_time='hour' ORDER BY id LIMIT 1")
FORM=$(id_de "SELECT id FROM glpi_forms_forms WHERE is_deleted=0 AND name LIKE '%materiel%' ORDER BY id LIMIT 1")

a_le_profil() {
    # $1 id utilisateur, $2 nom du profil
    au_moins 1 "SELECT COUNT(*) FROM glpi_profiles_users pu JOIN glpi_profiles p ON p.id=pu.profiles_id
                WHERE pu.users_id=$1 AND p.name='$2'"
}

# Tickets de demande déposés par marie.demandeur
DEMANDES="SELECT t.id FROM glpi_tickets t JOIN glpi_tickets_users u ON u.tickets_id=t.id
          WHERE t.is_deleted=0 AND t.type=2 AND u.type=1 AND u.users_id=$MARIE"

# ---------- Contrôles ----------

t_groupes() { [ "$N1" -gt 0 ] && [ "$N2" -gt 0 ]; }
t_marie()   { [ "$MARIE" -gt 0 ] && a_le_profil "$MARIE" "Self-Service"; }
t_paul()    { [ "$PAUL" -gt 0 ] && a_le_profil "$PAUL" "Self-Service"; }
t_tech()    { [ "$TECH" -gt 0 ] && a_le_profil "$TECH" "Technician"; }
t_tech_n1() { [ "$TECH" -gt 0 ] && [ "$N1" -gt 0 ] && au_moins 1 "SELECT COUNT(*) FROM glpi_groups_users WHERE users_id=$TECH AND groups_id=$N1"; }

t_sla()      { [ "$SLA" -gt 0 ]; }
t_escalade() { [ "$SLA" -gt 0 ] && au_moins 1 "SELECT COUNT(*) FROM glpi_slalevels WHERE slas_id=$SLA"; }

t_formulaire() {
    [ "$FORM" -gt 0 ] && au_moins 1 "SELECT COUNT(*) FROM glpi_forms_forms WHERE id=$FORM AND is_active=1 AND is_draft=0"
}
t_questions() {
    [ "$FORM" -gt 0 ] && au_moins 4 "SELECT COUNT(*) FROM glpi_forms_questions q
        JOIN glpi_forms_sections s ON s.id=q.forms_sections_id WHERE s.forms_forms_id=$FORM"
}
t_destination() {
    [ "$FORM" -gt 0 ] && au_moins 1 "SELECT COUNT(*) FROM glpi_forms_destinations_formdestinations
        WHERE forms_forms_id=$FORM AND itemtype LIKE '%FormDestinationTicket'"
}
t_categorie_catalogue() {
    [ "$FORM" -gt 0 ] && au_moins 1 "SELECT COUNT(*) FROM glpi_forms_forms WHERE id=$FORM AND forms_categories_id>0"
}

t_demande_marie() { [ "$MARIE" -gt 0 ] && au_moins 1 "SELECT COUNT(*) FROM ($DEMANDES) d"; }
t_validation() {
    [ "$MARIE" -gt 0 ] && au_moins 1 "SELECT COUNT(*) FROM glpi_ticketvalidations v
        WHERE v.status=3 AND v.tickets_id IN ($DEMANDES)"
}
t_sla_ticket() {
    [ "$MARIE" -gt 0 ] && au_moins 1 "SELECT COUNT(*) FROM glpi_tickets WHERE slas_id_ttr>0 AND id IN ($DEMANDES)"
}
t_resolue_n1() {
    [ "$MARIE" -gt 0 ] && [ "$N1" -gt 0 ] && au_moins 1 "SELECT COUNT(*) FROM glpi_tickets t
        JOIN glpi_groups_tickets g ON g.tickets_id=t.id AND g.type=2 AND g.groups_id=$N1
        WHERE t.status IN (5,6) AND t.id IN ($DEMANDES)"
}

t_notifications() {
    [ "$(sql "SELECT value FROM glpi_configs WHERE context='core' AND name='use_notifications'")" = "1" ] &&
    [ "$(sql "SELECT value FROM glpi_configs WHERE context='core' AND name='notifications_mailing'")" = "1" ]
}
t_file_attente() { au_moins 1 "SELECT COUNT(*) FROM glpi_queuednotifications"; }

# ---------- Exécution ----------

echo "${GRAS}Vérification du TP3 : catalogue de services et demandes ($(hostname))${RAZ}"

section "Acteurs"
verifier "Groupes Support N1 et Support N2" \
    "Administration, Groupes (Partie 1)" t_groupes
verifier "marie.demandeur, profil Self-Service" \
    "Administration, Utilisateurs : compte marie.demandeur avec le profil Self-Service (Partie 1)" t_marie
verifier "paul.resp, profil Self-Service" \
    "Administration, Utilisateurs : compte paul.resp avec le profil Self-Service (Partie 1)" t_paul
verifier "tech.n1, profil Technician" \
    "Administration, Utilisateurs : compte tech.n1 avec le profil Technician (Partie 1)" t_tech
verifier "tech.n1 membre du groupe Support N1" \
    "fiche de tech.n1, onglet Groupes (Partie 1)" t_tech_n1

section "Niveau de service"
verifier "SLA de temps de résolution de 8 heures" \
    "Configuration, Niveaux de services : SLA de type Temps de résolution, 8 heures (Partie 2)" t_sla
verifier "Niveau d'escalade sur ce SLA" \
    "dans le SLA, onglet Niveaux d'escalade (Partie 2)" t_escalade

section "Formulaire et catalogue"
verifier "Formulaire « Demande de nouveau matériel » actif" \
    "Administration, Formulaires : crée-le, puis rends-le actif (Parties 3 et 4)" t_formulaire
verifier "Au moins quatre questions dans le formulaire" \
    "type de matériel, justification, date souhaitée, urgence (Partie 3)" t_questions
verifier "Destination : le formulaire crée un ticket" \
    "onglet Destinations du formulaire : destination Ticket (Partie 3)" t_destination
verifier "Formulaire rangé dans une catégorie du catalogue" \
    "dans le formulaire, champ Catégorie (Partie 4)" t_categorie_catalogue

section "Chaîne de bout en bout"
verifier "Demande déposée par marie.demandeur (ticket de type Demande)" \
    "connecte-toi en marie.demandeur et remplis le formulaire depuis le catalogue (Partie 7)" t_demande_marie
verifier "Validation approuvée sur cette demande" \
    "validation demandée à paul.resp, puis approuvée en se connectant avec son compte (Parties 5 et 7)" t_validation
verifier "SLA attaché à la demande" \
    "destination du formulaire : associe le SLA Résolution standard 8h (Partie 3)" t_sla_ticket
verifier "Demande résolue et attribuée au groupe Support N1" \
    "dans le ticket : Attribué à Support N1, puis solution (Partie 7)" t_resolue_n1

section "Notifications"
verifier "Notifications et suivi par courriel activés" \
    "Configuration, Notifications : active les notifications et le suivi par courriel (Partie 6)" t_notifications
verifier "Au moins une notification dans la file d'attente" \
    "renseigne une adresse de courriel sur les comptes, puis rejoue une étape de la Partie 7 (Partie 6)" t_file_attente

# ---------- Verdict ----------
if [ "$DETAILS" -eq 1 ]; then printf '%s\n' "${lignes[@]}"; echo; fi

if [ "$reussis" -eq "$total" ]; then
    echo "${VERT}${GRAS}Tout est en place (${reussis}/${total}).${RAZ}"
    exit 0
else
    echo "${ROUGE}${GRAS}${reussis}/${total} contrôles validés : $((total - reussis)) élément(s) manquant(s).${RAZ}"
    [ "$DETAILS" -eq 0 ] && echo "Relance avec : sudo ./verif-tp3.sh --details pour savoir quoi corriger."
    exit 1
fi
