# Securite

## Signaler une vulnerabilite

Par un [avis de securite prive GitHub](https://github.com/jbsky/radicale-hardened/security/advisories/new),
pas par une issue publique.

Une vulnerabilite de Radicale lui-meme releve de l'amont :
<https://github.com/Kozea/Radicale/security>. Elle est corrigee ici par une
montee de version dans `versions.json` (automatique, `version-watch`).

## Ce que la CI bloque, et ce qu'elle rapporte seulement

| Perimetre | Scanne | Effet |
|---|---|---|
| Paquets Alpine copies dans l'image (musl, OpenSSL, expat, libffi, libgcc) | Trivy sur le stage `prep`, a chaque build ; `cve-watch` chaque jour sur la SBOM attestee | **bloque** sur un CRITICAL corrigeable ; une CVE de paquet Alpine corrigeable declenche une reconstruction automatique |
| Paquets Python (`site-packages` : Radicale et ses dependances) | Trivy sur le stage `prep` et sur l'image publiee ; Trivy + Grype chaque mardi | **bloque** sur un CRITICAL corrigeable au build ; rapport SARIF + une issue tenue a jour |
| CPython (image `python:3.15-alpine`) | idem | le correctif arrive par le digest de base, suivi chaque jour par `base-watch` |
| init Go | Trivy (`gobinary`) | le correctif arrive par le digest `golang`, ou par `go.mod` |

## Chaine d'approvisionnement Python

- **Radicale** : roue PyPI, sha256 epingle dans `versions.json`. `version-watch`
  n'ecrit ce sha256 qu'apres avoir verifie l'attestation Trusted Publishing
  de la roue (`pypi-attestations verify pypi --repository
  https://github.com/Kozea/Radicale`) : un sha256 recopie d'un fichier non
  authentifie ne prouverait rien.
- **Dependances** : `requirements.txt`, un fichier par paquet et son sha256,
  installe avec `pip --require-hashes --no-deps` puis `pip check`. Aucun
  resolveur ne choisit de version au build. Les montees arrivent par
  Dependabot (ecosysteme `pip`).
- **bcrypt** : seul code natif hors CPython. Compile depuis son archive
  source (sha256 epingle) ; les crates Rust sont recuperees avec
  `cargo fetch --locked` -- sommes de controle du `Cargo.lock` de l'amont --
  puis la compilation tourne **hors ligne**. Le build echoue si le module
  n'est pas BIND_NOW, RELRO, pile non executable.
- **Outils de build** (setuptools, wheel, setuptools-rust) : epingles de meme
  dans `requirements-build.txt`, installes dans un venv qui ne quitte pas le
  stage `pybuild`.
- **pip** n'est pas dans l'image : ses declarations vendues (`vendor.txt`)
  faisaient remonter a Trivy des paquets qui ne s'executent pas.

## Derogations

Aucune a ce jour. Une derogation s'ecrit dans `.trivyignore` avec une date
d'expiration et, a l'identique, dans `.grype.yaml`, et se justifie ici.
