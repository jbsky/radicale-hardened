#!/bin/sh
# ci-users.sh -- fichier htpasswd du compose de test (champ `setup` de
# .github/hardened-ci.json, joue par hardened-ci avant `docker compose up`).
#
# L'init refuse de demarrer sans fichier d'utilisateurs : sans lui, le service
# ne deviendrait jamais healthy. Le compte est un compte de TEST, au mot de
# passe public (radicale-ci) : ce fichier ne sert qu'au conteneur de la CI et
# n'est pas versionne (.gitignore).
#
# Mode 0644 : le fichier appartient a l'uid du runner, l'image tourne en
# 5232 ; en production, chown root:5232 et chmod 640 (cf. README).
set -eu
cd "$(dirname "$0")/.."
umask 022
# shellcheck disable=SC2016 # un hash bcrypt, pas une expansion
printf '%s\n' 'ci:$2b$10$lXTMS9BMzEOwKLjDpdHmrOB7K5aZSG/rf388miOzuMZpgYs4a/DZC' > users
echo "ci-users: ./users ecrit (compte de test « ci »)"
