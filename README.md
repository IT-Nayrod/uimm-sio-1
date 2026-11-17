# uimm-sio-1

Scripts des TP du BTS SIO 1 : simulation d'activité et vérification de fin de TP.

## Récupérer le dépôt

Sur la VM indiquée dans le TP :

```bash
cd ~
git clone https://github.com/IT-Nayrod/uimm-sio-1.git
```

Si le dépôt est déjà cloné, mets-le à jour :

```bash
cd ~/uimm-sio-1 && git pull
```

## Contenu

| Dossier | TP | Scripts |
| --- | --- | --- |
| `supportsi/tp1-glpi` | Support SI, TP Découverte : GLPI sur Serveur-Cyber | `verif-tp1.sh` (vérification, sur Serveur-Cyber) |
| `supportsi/tp2-incidents` | Support SI, TP2 : incidents automatiques et API de GLPI | scripts `incident-*.sh` (sur client2 et client3), `verif-tp2.sh` (vérification, sur Serveur-Cyber) |
| `supportsi/tp3-catalogue` | Support SI, TP3 : catalogue de services, formulaires et demandes | `verif-tp3.sh` (vérification, sur Serveur-Cyber) |
| `supportsi/tp4-snmp` | Support SI, TP4 : découverte réseau SNMP avec GLPI | `verif-tp4.sh` (vérification, sur Serveur-Cyber) |

## Scripts de vérification

Chaque TP se termine par un script de vérification, à lancer avec sudo sur la VM indiquée dans le TP :

```bash
sudo ./verif-tpX.sh            # verdict global
sudo ./verif-tpX.sh --details  # détail de ce qui manque et comment le corriger
```

Ne passe au TP suivant que lorsque le script affiche « Tout est en place ».

Les scripts fonctionnent sur Ubuntu 24.04 comme sur Ubuntu 26.04.
