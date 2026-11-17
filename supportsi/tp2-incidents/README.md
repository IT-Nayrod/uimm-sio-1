# Scripts d'incidents : centre de services GLPI (BTS SIO 1, Support SI, TP2)

Ces scripts simulent des incidents sur un poste et ouvrent automatiquement
un ticket dans GLPI via son API REST.

## Prérequis
- git et curl installés : `sudo apt install -y git curl`
- Le serveur GLPI du TP Découverte (Serveur-Cyber, port 8080) avec l'API REST
  activée, un client API (app-token) et le compte de service `automate`
  dont on a la clé d'accès distant (user-token).

## Mise en route
1. Copier le fichier d'exemple et y coller ses deux jetons :
   `cp glpi.env.exemple glpi.env` puis `nano glpi.env`
2. Rendre les scripts exécutables : `chmod +x *.sh`
3. Lancer un scénario, par exemple : `./incident-disque-plein.sh`

## Quel script sur quel poste
- Poste bureautique (client2) : `incident-disque-plein.sh`,
  `incident-imprimante-injoignable.sh`, `incident-connexion-internet.sh`
- Poste technique (client3) : `incident-service-arrete.sh`,
  `incident-connexions-suspectes.sh`, `incident-charge-cpu.sh`

## Vérification de fin de TP
Sur Serveur-Cyber : `sudo ./verif-tp2.sh` (et `--details` pour savoir quoi corriger).

## Notes
- Le fichier `glpi.env` contient des secrets : il n'est jamais versionné.
- Certains scripts (connexions suspectes) remontent davantage avec sudo.
