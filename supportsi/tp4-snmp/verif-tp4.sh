#!/bin/bash
# ------------------------------------------------------------------
# BTS SIO 1, Support SI, TP4 : découverte réseau SNMP avec GLPI
# Script de vérification, à lancer sur Serveur-Cyber :
#
#   sudo ./verif-tp4.sh             verdict global
#   sudo ./verif-tp4.sh --details   détail de chaque contrôle et quoi corriger
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

# Client SQL : la commande s'appelle mariadb (le nom mysql n'existe plus par défaut avec MariaDB 11)
CLIENT_SQL=$(command -v mariadb || command -v mysql)

BASE=$(sed -n "s/.*dbdefault *= *'\([^']*\)'.*/\1/p" "$GLPI_DIR/config/config_db.php" 2>/dev/null)
[ -z "$BASE" ] && BASE="glpi"
sql()    { "$CLIENT_SQL" --default-character-set=utf8mb4 -N -B "$BASE" -e "$1" 2>/dev/null; }
nombre() { local n; n=$(sql "$1"); [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0; }
au_moins() { [ "$(nombre "$2")" -ge "$1" ]; }

if [ -z "$(sql "SELECT 1")" ]; then
    echo "${ROUGE}Base de GLPI introuvable : lance ce script sur Serveur-Cyber, après le TP Découverte.${RAZ}"
    exit 2
fi

# Équipements réseau inventoriés (hors corbeille et gabarits)
EQUIPEMENTS="SELECT id FROM glpi_networkequipments WHERE is_deleted=0 AND is_template=0"

module_reseau_actif() {
    # $1 NETWORKDISCOVERY ou NETWORKINVENTORY, $2 colonne équivalente dans glpi_agents
    au_moins 1 "SELECT COUNT(*) FROM glpi_plugin_glpiinventory_agentmodules
                WHERE modulename='$1' AND (is_active=1 OR (exceptions IS NOT NULL AND exceptions NOT IN ('', '[]')))" ||
    au_moins 1 "SELECT COUNT(*) FROM glpi_agents WHERE $2=1"
}

tache_active() {
    # $1 méthode : networkdiscovery ou networkinventory
    au_moins 1 "SELECT COUNT(*) FROM glpi_plugin_glpiinventory_taskjobs j
                JOIN glpi_plugin_glpiinventory_tasks t ON t.id=j.plugin_glpiinventory_tasks_id
                WHERE t.is_active=1 AND j.method='$1'"
}

# ---------- Contrôles ----------

t_plugin()       { au_moins 1 "SELECT COUNT(*) FROM glpi_plugins WHERE directory='glpiinventory' AND state=1"; }
t_identifiant()  { au_moins 1 "SELECT COUNT(*) FROM glpi_snmpcredentials WHERE is_deleted=0 AND snmpversion=2 AND community<>''"; }
t_plage()        { au_moins 1 "SELECT COUNT(*) FROM glpi_plugin_glpiinventory_ipranges WHERE ip_start<>'' AND ip_end<>''"; }
t_plage_ident()  {
    au_moins 1 "SELECT COUNT(*) FROM glpi_plugin_glpiinventory_ipranges_snmpcredentials a
                JOIN glpi_snmpcredentials c ON c.id=a.snmpcredentials_id WHERE c.is_deleted=0"
}
t_module_decouverte() { module_reseau_actif NETWORKDISCOVERY use_module_network_discovery; }
t_module_inventaire() { module_reseau_actif NETWORKINVENTORY use_module_network_inventory; }
t_tache_decouverte()  { tache_active networkdiscovery; }
t_tache_inventaire()  { tache_active networkinventory; }

t_equipement() {
    au_moins 1 "SELECT COUNT(*) FROM glpi_networkequipments WHERE id IN ($EQUIPEMENTS) AND snmpcredentials_id>0"
}
t_localisation() {
    au_moins 1 "SELECT COUNT(*) FROM glpi_networkequipments n JOIN glpi_locations l ON l.id=n.locations_id
                WHERE n.id IN ($EQUIPEMENTS) AND l.completename LIKE '%B12%'"
}
t_inventaire_detaille() {
    # L'inventaire SNMP remonte toutes les interfaces : plusieurs ports réseau sur l'équipement
    au_moins 2 "SELECT COUNT(*) FROM glpi_networkports p
                WHERE p.itemtype='NetworkEquipment' AND p.is_deleted=0 AND p.items_id IN ($EQUIPEMENTS)
                GROUP BY p.items_id ORDER BY COUNT(*) DESC LIMIT 1"
}
t_plus_ordinateur() {
    [ "$(nombre "SELECT COUNT(*) FROM glpi_computers WHERE is_template=0 AND name LIKE 'client3%'")" -eq 0 ]
}

# ---------- Exécution ----------

echo "${GRAS}Vérification du TP4 : découverte réseau SNMP ($(hostname))${RAZ}"

section "Préparation de client3"
verifier "client3 n'est plus déclaré comme ordinateur (purgé, agent coupé)" \
    "sur client3 : sudo systemctl disable --now glpi-agent ; dans GLPI : Parc, Ordinateurs, client3 à la corbeille puis purgé (Partie 1)" t_plus_ordinateur

section "Configuration de la découverte"
verifier "Plugin GLPI Inventory installé et activé" \
    "Configuration, Plugins : installe puis active GLPI Inventory, ou installation manuelle 1.6.12 (Partie 3)" t_plugin
verifier "Identifiant SNMP v2c avec une communauté" \
    "Administration, Inventaire, icône cadenas : identifiant v2c, communauté public (Partie 4)" t_identifiant
verifier "Plage IP déclarée" \
    "GLPI Inventory, Réseau, Plages IP : 192.168.50.1 à 192.168.50.254 (Partie 4)" t_plage
verifier "Identifiant SNMP associé à la plage IP" \
    "fiche de la plage IP : associe l'identifiant SNMP (Partie 4)" t_plage_ident
verifier "Module Découverte réseau activé sur un agent" \
    "GLPI Inventory, Général, Gestion des agents, agent de Client-Cyber, onglet Modules des agents (Partie 4)" t_module_decouverte
verifier "Module Inventaire réseau (SNMP) activé sur un agent" \
    "même onglet Modules des agents : coche Inventaire réseau (SNMP) (Partie 4)" t_module_inventaire

section "Tâches et résultat"
verifier "Tâche de découverte réseau active" \
    "GLPI Inventory, Tâches, Gestion des tâches : tâche de découverte réseau (Partie 5, temps 1)" t_tache_decouverte
verifier "Tâche d'inventaire réseau active" \
    "GLPI Inventory, Tâches, Gestion des tâches : tâche d'inventaire réseau (Partie 5, temps 2)" t_tache_inventaire
verifier "Un matériel réseau découvert en SNMP" \
    "Forcer le démarrage de la découverte, puis sudo glpi-agent --force sur Client-Cyber (Partie 5)" t_equipement
verifier "Sa localisation Salle B12 remontée par SNMP" \
    "syslocation Salle B12 dans /etc/snmp/snmpd.conf sur client3, puis nouveau scan (Partie 1)" t_localisation
verifier "Inventaire SNMP détaillé : plusieurs ports réseau remontés" \
    "Forcer le démarrage de l'inventaire, puis sudo glpi-agent --force sur Client-Cyber (Partie 5, temps 2)" t_inventaire_detaille

# ---------- Verdict ----------
if [ "$DETAILS" -eq 1 ]; then printf '%s\n' "${lignes[@]}"; echo; fi

if [ "$reussis" -eq "$total" ]; then
    echo "${VERT}${GRAS}Tout est en place (${reussis}/${total}).${RAZ}"
    exit 0
else
    echo "${ROUGE}${GRAS}${reussis}/${total} contrôles validés : $((total - reussis)) élément(s) manquant(s).${RAZ}"
    [ "$DETAILS" -eq 0 ] && echo "Relance avec : sudo ./verif-tp4.sh --details pour savoir quoi corriger."
    exit 1
fi
