# Contribuer

Deux regles, pas plus.

## 1. Signer ses commits (`Signed-off-by`)

Chaque commit doit porter la ligne :

```
Signed-off-by: Prenom Nom <adresse@example.com>
```

`git commit -s` l'ajoute pour vous.

C'est le [Developer Certificate of Origin](https://developercertificate.org/) :
vous attestez avoir le droit de soumettre ce code sous la licence du depot.

## 2. Les tests doivent passer

Avant toute pull request, construire l'image et rejouer les tests en local :

```bash
make build && make test
make check
```

Une version ne s'ecrit que dans `versions.json`, avec son sha256 dans le meme
commit. Une dependance Python ne s'ecrit que dans `requirements.txt` (ou
`requirements-build.txt` pour les outils de build de bcrypt), avec le sha256
d'un seul fichier : la roue `py3-none-any`, ou l'archive source pour bcrypt.
Le Dockerfile n'a volontairement aucune valeur par defaut.

Un changement qui deplace des fichiers dans l'image (montee de Python, d'une
dependance, purge) regenere `image.manifest` dans le meme commit :

```bash
python3 ../hardened-ci/scripts/image-manifest.py --generate localhost/radicale-hardened:latest -o image.manifest
```
