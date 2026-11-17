#!/usr/bin/env bash
# tp4_check.sh - Vérification serveur TP4 (clé SSH + mot de passe, clés globales)
# Usage :
#   sudo ./tp4_check.sh                 -> sortie courte
#   sudo ./tp4_check.sh -v              -> sortie détaillée
#   sudo ./tp4_check.sh --user etudiant -> cible un autre utilisateur

set -euo pipefail

VERBOSE=0
TARGET_USER="etudiant"

# Parse args simples
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    --user) TARGET_USER="${2:-etudiant}"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "il y a des éléments du TP4 manquants ou mal configurés"
  [[ $VERBOSE -eq 1 ]] && echo "[ERREUR] Lance ce script avec sudo."
  exit 1
fi

say() { [[ $VERBOSE -eq 1 ]] && echo -e "$*"; }

pass() { say "OK   - $*"; }
fail() { say "FAIL - $*"; }

all_good=1

# --- 1) SSH service et config effective --------------------------------------
check_ssh() {
  local ok_service=0 ok_rootlogin=0 ok_pw=0 ok_pubkey=0 ok_authfile=0

  if systemctl is-active --quiet ssh; then
    ok_service=1
    pass "Service ssh actif"
  else
    fail "Service ssh inactif"
  fi

  if command -v sshd &>/dev/null; then
    local eff
    eff="$(sshd -T 2>/dev/null || true)"

    if grep -iq "^permitrootlogin no$" <<<"$eff"; then ok_rootlogin=1; pass "PermitRootLogin = no"; else fail "PermitRootLogin attendu: no"; fi
    if grep -iq "^passwordauthentication yes$" <<<"$eff"; then ok_pw=1; pass "PasswordAuthentication = yes"; else fail "PasswordAuthentication attendu: yes"; fi
    if grep -iq "^pubkeyauthentication yes$" <<<"$eff"; then ok_pubkey=1; pass "PubkeyAuthentication = yes"; else fail "PubkeyAuthentication attendu: yes"; fi

    # AuthorizedKeysFile peut avoir plusieurs chemins, on exige le global
    # Exemple attendu : AuthorizedKeysFile /etc/ssh/authorized_keys/%u
    if grep -iq '^authorizedkeysfile .*\/etc\/ssh\/authorized_keys\/%u' <<<"$eff"; then
      ok_authfile=1
      pass "AuthorizedKeysFile global = /etc/ssh/authorized_keys/%u"
    else
      fail "AuthorizedKeysFile ne pointe pas vers /etc/ssh/authorized_keys/%u"
    fi
  else
    fail "sshd introuvable"
  fi

  [[ $ok_service -eq 1 && $ok_rootlogin -eq 1 && $ok_pw -eq 1 && $ok_pubkey -eq 1 && $ok_authfile -eq 1 ]]
}

# --- 2) Clé globale présente et droits corrects --------------------------------
check_global_keys() {
  local dir="/etc/ssh/authorized_keys"
  local file="$dir/$TARGET_USER"

  local ok_dir=0 ok_file=0 ok_perm_dir=0 ok_perm_file=0 ok_owner=0

  if [[ -d "$dir" ]]; then
    ok_dir=1
    # droits 755 : sshd doit pouvoir traverser le dossier avec l'identité de l'utilisateur
    local dperm; dperm="$(stat -c '%a' "$dir" 2>/dev/null || echo '')"
    [[ "$dperm" == "755" ]] && ok_perm_dir=1
    # propriétaire root
    local downer; downer="$(stat -c '%U:%G' "$dir" 2>/dev/null || echo '')"
    [[ "$downer" == "root:root" ]] && ok_owner=1
  fi

  if [[ -f "$file" ]]; then
    ok_file=1
    # droits 644 et propriétaire root : lisible par l'utilisateur, modifiable par root seul
    local fperm; fperm="$(stat -c '%a' "$file" 2>/dev/null || echo '')"
    local fowner; fowner="$(stat -c '%U:%G' "$file" 2>/dev/null || echo '')"
    [[ "$fperm" == "644" && "$fowner" == "root:root" ]] && ok_perm_file=1
  fi

  # Verbose détails
  if [[ $VERBOSE -eq 1 ]]; then
    echo "Répertoire global : $dir"
    echo "  Existe : $([[ $ok_dir -eq 1 ]] && echo oui || echo non)"
    [[ $ok_dir -eq 1 ]] && echo "  Droits : $(stat -c '%a' "$dir") (attendu 755), Propriétaire : $(stat -c '%U:%G' "$dir") (attendu root:root)"
    echo "Fichier clé : $file"
    echo "  Existe : $([[ $ok_file -eq 1 ]] && echo oui || echo non)"
    [[ $ok_file -eq 1 ]] && echo "  Droits : $(stat -c '%a' "$file") (attendu 644), Propriétaire : $(stat -c '%U:%G' "$file") (attendu root:root)"
  fi

  local ok=$(( ok_dir & ok_file & ok_perm_dir & ok_perm_file & ok_owner ))
  if [[ $ok -eq 1 ]]; then
    pass "Clé globale OK pour l'utilisateur $TARGET_USER"
    return 0
  else
    fail "Clé globale manquante ou droits/propriétaire incorrects pour $TARGET_USER"
    return 1
  fi
}

# --- 3) UFW et ports ----------------------------------------------------------
check_ufw() {
  if ! command -v ufw &>/dev/null; then
    fail "ufw non installé"
    return 1
  fi

  local active=0 p22=0 p80=0
  if ufw status | grep -q "Status: active"; then active=1; fi
  if ufw status | grep -Eq "(OpenSSH|22/tcp).*ALLOW|ALLOW.*(OpenSSH|22/tcp)"; then p22=1; fi
  if ufw status | grep -Eq "(80/tcp).*ALLOW|ALLOW.*(80/tcp)"; then p80=1; fi

  [[ $active -eq 1 ]] && pass "UFW actif" || fail "UFW inactif"
  [[ $p22 -eq 1 ]] && pass "Port 22/tcp autorisé" || fail "Port 22/tcp non autorisé"
  [[ $p80 -eq 1 ]] && pass "Port 80/tcp autorisé" || fail "Port 80/tcp non autorisé"

  [[ $active -eq 1 && $p22 -eq 1 && $p80 -eq 1 ]]
}

# --- 4) Nginx et page web -----------------------------------------------------
check_nginx() {
  local ok_service=0 ok_http=0

  if systemctl is-active --quiet nginx; then ok_service=1; pass "nginx actif"; else fail "nginx inactif"; fi

  # On tente un curl local
  if command -v curl &>/dev/null; then
    if curl -sS -m 3 -o /tmp/tp4_http.out -w "%{http_code}" http://localhost/ | grep -qE "200|301|302"; then
      # vérif contenu (optionnel) : “SecureLab”
      if grep -qi "SecureLab" /tmp/tp4_http.out 2>/dev/null || curl -sS http://localhost/ | grep -qi "SecureLab"; then
        ok_http=1
        pass "HTTP OK (contenu visible)"
      else
        # le site peut ne pas contenir ce mot, on valide sur code HTTP
        ok_http=1
        pass "HTTP OK (code HTTP valide)"
      fi
    else
      fail "HTTP indisponible sur localhost"
    fi
    rm -f /tmp/tp4_http.out || true
  else
    fail "curl non installé (test HTTP sauté)"
  fi

  [[ $ok_service -eq 1 && $ok_http -eq 1 ]]
}

# -------------------- Lancer les vérifications -------------------------------
check_ssh        || all_good=0
check_global_keys|| all_good=0
check_ufw        || all_good=0
check_nginx      || all_good=0

if [[ $all_good -eq 1 ]]; then
  echo "tout est bon"
  exit 0
else
  echo "il y a des éléments du TP4 manquants ou mal configurés"
  exit 1
fi
