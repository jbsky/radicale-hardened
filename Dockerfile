# syntax=docker/dockerfile:1
# =====================================================================
#  Radicale Hardened -- Tier Platine (FROM scratch)
#  pybuild -> gobuilder -> prep -> scratch
# =====================================================================
# Pas de valeur par defaut, volontairement : versions.json est la seule source
# de verite. Le Makefile et la CI passent ces ARG par
# scripts/versions-build-args.py (cle `radicale` -> RADICALE_VERSION) ; un
# `docker build` nu echoue avec un message.
#
# Radicale publie sur PyPI par Trusted Publishing (workflow pypi-publish.yml
# de Kozea/Radicale) : version-watch verifie cette attestation avant d'ecrire
# le sha256 de la roue dans versions.json. Au build, c'est ce sha256 qui fait
# foi (pip --require-hashes).
ARG RADICALE_VERSION
ARG RADICALE_SHA256
# Pas d'ARG ALPINE_VERSION ni PYTHON_VERSION : les FROM epinglent tag ET
# digest en litteral, et scripts/versions-build-args.py --check compare ces
# tags a .alpine et .python.

# --- pybuild : Radicale et ses dependances, bcrypt compile ici ---------
# Le runtime Python vient de l'image officielle python:<x.y>-alpine, comme
# dans suricata-hardened : elle compile CPython depuis les sources sur la meme
# Alpine, et sert la mineure courante sans attendre un repaquetage apk.
FROM python:3.15-alpine@sha256:0f9552bb28711333da16915ec146f5e6bb44a7fdac9ced15dc17c2e0206346dd AS pybuild
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG RADICALE_VERSION
ARG RADICALE_SHA256
RUN test -n "${RADICALE_VERSION}" -a -n "${RADICALE_SHA256}" \
    || { echo "RADICALE_VERSION et RADICALE_SHA256 sont requis : make build, ou docker build \$(scripts/versions-build-args.py --docker) ." >&2; exit 1; }

# Garde. Les COPY et les purges du stage prep nomment python3.15 en dur -- le
# chemin des modules est la mineure -- et image.manifest enumere les fichiers
# qui en decoulent. Une mineure qui bouge sous ces lignes (PR Dependabot sur
# le tag ci-dessus) echoue ici, en une seconde et avec la marche a suivre.
RUN PYV="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')" \
 && if [ "$PYV" != "3.15" ]; then \
      echo "ERREUR: base python ${PYV}, alors que ce Dockerfile, versions.json (.python) et image.manifest nomment 3.15." >&2; \
      echo "Bump de mineure : remplacer 3.15 par ${PYV} dans Dockerfile et versions.json, puis regenerer image.manifest." >&2; \
      exit 1; \
    fi

# Proxy SSL-bump : depots apk en HTTP, CA interne en secret BuildKit (jamais
# en couche ; ce stage n'est pas publie). Rust compile le module de bcrypt ;
# gcc et musl-dev fournissent l'editeur de liens.
RUN sed -i 's|https://|http://|g' /etc/apk/repositories
RUN --mount=type=secret,id=ca-certs,required=false \
    if [ -f /run/secrets/ca-certs ]; then \
      cat /run/secrets/ca-certs >> /etc/ssl/certs/ca-certificates.crt; \
    fi \
 && apk add --no-cache cargo rust gcc musl-dev binutils

# Outils de build dans un venv a part : setuptools, wheel, setuptools-rust ne
# doivent pas finir dans le site-packages qui sera publie.
COPY requirements.txt requirements-build.txt /tmp/req/
RUN python3 -m venv /opt/build \
 && /opt/build/bin/pip install --no-cache-dir --require-hashes --no-deps \
      --only-binary :all: -r /tmp/req/requirements-build.txt

# Telechargement verifie : chaque fichier doit avoir le sha256 du lockfile,
# roue py3-none-any pour le Python pur, archive source pour bcrypt. Radicale
# arrive par la meme voie, avec la version et le sha256 de versions.json.
WORKDIR /src
RUN printf 'radicale==%s --hash=sha256:%s\n' "${RADICALE_VERSION}" "${RADICALE_SHA256}" > /tmp/req/radicale.txt \
 && pip download --no-cache-dir --require-hashes --no-deps \
      --only-binary :all: --no-binary bcrypt \
      -r /tmp/req/requirements.txt -r /tmp/req/radicale.txt -d /src/dl \
 && test -f "/src/dl/radicale-${RADICALE_VERSION}-py3-none-any.whl"

# bcrypt : les crates sont recuperees avec --locked (le Cargo.lock de
# l'archive fait foi, sommes de controle comprises), puis la compilation
# tourne hors ligne -- elle ne peut utiliser que ce qui vient d'etre verifie.
# Les cibles Linux de Rust posent deja full RELRO et NX ; les drapeaux le
# redisent a l'editeur de liens, et le .so est verifie apres coup : BIND_NOW,
# GNU_RELRO, pile non executable.
ENV CARGO_HOME=/opt/cargo \
    RUSTFLAGS="-C link-arg=-Wl,-z,relro,-z,now -C link-arg=-Wl,-z,noexecstack -C strip=symbols"
RUN mkdir bcrypt \
 && tar -xzf dl/bcrypt-*.tar.gz -C bcrypt --strip-components=1 \
 && rm dl/bcrypt-*.tar.gz \
 && cargo fetch --locked --manifest-path bcrypt/src/_bcrypt/Cargo.toml \
 && CARGO_NET_OFFLINE=true /opt/build/bin/pip wheel --no-cache-dir --no-build-isolation \
      --no-deps -w /src/dl ./bcrypt \
 && so="$(python3 -c 'import glob, zipfile; z = zipfile.ZipFile(glob.glob("/src/dl/bcrypt-*.whl")[0]); n = [m for m in z.namelist() if m.endswith(".so")]; assert len(n) == 1, n; print(z.extract(n[0], "/tmp/so"))')" \
 && readelf -d "${so}" > /tmp/so.dyn \
 && grep -q BIND_NOW /tmp/so.dyn \
 && readelf -lW "${so}" | grep -q GNU_RELRO \
 && ! readelf -lW "${so}" | grep GNU_STACK | grep -q RWE \
 && rm -rf /tmp/so /tmp/so.dyn

# Installation dans le Python systeme (/usr/local), sans index : uniquement
# les roues verifiees ci-dessus. `pip check` refuse un arbre que Radicale ou
# une dependance n'accepte pas (lockfile et versions.json desaccordes).
RUN pip install --no-cache-dir --no-index --no-deps /src/dl/*.whl \
 && pip check \
 && python3 -c "import radicale, sys; v = radicale.VERSION; sys.exit(0 if v == '${RADICALE_VERSION}' else 'radicale ' + v + ' installe, ${RADICALE_VERSION} attendu')"

# --- gobuilder : init statique (entrypoint + healthcheck + setup-dirs) -
FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS gobuilder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
    go build -ldflags='-s -w' -trimpath -o /init .

# --- prep : arborescence runtime, cloture resolue au build -------------
# Ce stage garde sa base apk ET le site-packages : c'est lui que lisent le
# scan CVE et la SBOM attestee (paquets Alpine + paquets Python). L'image
# finale ne prend que /rootfs.
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS prep
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# openssl : _ssl et _hashlib (TLS servi par Radicale, hash des mots de passe
# hors bcrypt). expat : pyexpat, donc tout le XML de WebDAV. libffi : _ctypes,
# que radicale/pathutils.py importe sans condition sous Linux (renameat2,
# echange atomique de collections). libgcc : le module Rust de bcrypt
# (deroulement de pile). Rien d'autre : un module de lib-dynload dont la
# bibliotheque manque ici (_bz2, _lzma, _sqlite3...) est supprime plus bas,
# et la sonde de fin de stage prouve que Radicale n'en importe aucun.
RUN sed -i 's|https://|http://|g' /etc/apk/repositories \
 && apk upgrade --no-cache \
 && apk add --no-cache openssl expat libffi libgcc tini-static ca-certificates tzdata lddtree \
 && addgroup -S -g 5232 radicale \
 && adduser -S -D -H -u 5232 -G radicale -h /var/lib/radicale -s /sbin/nologin radicale

# libpython3.15.so.1.0 est a cote du repertoire des modules, pas dedans ; il
# est nomme en entier (un COPY par motif dereferencerait le lien
# libpython3.15.so en une seconde copie de 6 Mo).
COPY --from=pybuild /usr/local/bin/python3.15 /usr/local/bin/python3.15
COPY --from=pybuild /usr/local/lib/python3.15/ /usr/local/lib/python3.15/
COPY --from=pybuild /usr/local/lib/libpython3.15.so.1.0 /usr/local/lib/

# Ce qui ne sert pas a un serveur CalDAV/CardDAV, et ne s'execute donc pas :
#   pip, ensurepip, venv   -- rien ne s'installe au runtime ; pip vend en
#                             plus des declarations (vendor.txt) que Trivy
#                             lit comme des paquets
#   radicale/tests         -- la suite de tests de l'amont
#   tkinter, turtle*, idlelib, curses, sqlite3, dbm, pydoc_data, lib2to3,
#   config-3.15-*          -- interfaces graphiques, IDE, bases que Radicale
#                             n'utilise pas, en-tetes de compilation
#   lib-dynload/_test*, xx*, _ctypes_test*, _xxtestfuzz* -- extensions de la
#                             suite de tests de CPython
RUN P=/usr/local/lib/python3.15 \
 && rm -rf $P/ensurepip $P/venv \
           $P/site-packages/pip $P/site-packages/pip-*.dist-info \
           $P/site-packages/radicale/tests \
           $P/tkinter $P/turtledemo $P/turtle.py $P/idlelib $P/curses \
           $P/sqlite3 $P/dbm $P/pydoc_data $P/lib2to3 $P/config-3.15-* \
           $P/lib-dynload/_test* $P/lib-dynload/xx* \
           $P/lib-dynload/_ctypes_test* $P/lib-dynload/_xxtestfuzz* \
 && find $P -name '__pycache__' -type d -prune -exec rm -rf {} +

# Cloture : les racines sont l'interpreteur, libpython, chaque module C de
# lib-dynload (charges par dlopen, invisibles depuis python3) et le module de
# bcrypt. Un module de lib-dynload dont une dependance manque ici (_tkinter,
# _sqlite3, _curses, _gdbm, readline, _ctypes sans libffi...) ne pourrait
# jamais s'importer : il est supprime au lieu d'etre embarque casse.
# lddtree signale une dependance absente sur stderr et sort quand meme en 0 :
# la completude est verifiee sur la liste NON filtree, avant le filtre. Les
# racines sous /usr/local sont retirees de la liste (elles arrivent par cp)
# -- y compris le chemin non normalise /usr/local/bin/../lib/libpython...
RUN mkdir -p /rootfs \
 && find /usr/local/lib/python3.15/lib-dynload -name '*.so' > /tmp/dynload.list \
 && test -s /tmp/dynload.list \
 && while IFS= read -r m; do \
      lddtree -l "$m" > /dev/null 2> /tmp/mod.err || true; \
      if grep -q 'Not found' /tmp/mod.err; then \
        echo "lib-dynload : suppression de ${m} (dependance absente de cette image)"; \
        rm -f "$m"; \
      fi; \
    done < /tmp/dynload.list \
 && find /usr/local/lib/python3.15/site-packages -name '*.so' > /tmp/ext.list \
 && test "$(wc -l < /tmp/ext.list)" -eq 1 \
 && grep -q '/site-packages/bcrypt/_bcrypt' /tmp/ext.list \
 && { lddtree -l /usr/local/bin/python3.15 /usr/local/lib/libpython3.15.so.1.0; \
      find /usr/local/lib/python3.15/lib-dynload -name '*.so' -exec lddtree -l {} +; \
      xargs lddtree -l < /tmp/ext.list; } \
      > /tmp/closure.list 2> /tmp/closure.err \
 && if grep -q 'Not found' /tmp/closure.list /tmp/closure.err; then \
      echo "cloture incomplete -- une dependance manque a ce stage :" >&2; \
      grep 'Not found' /tmp/closure.list /tmp/closure.err >&2; \
      exit 1; \
    fi \
 && sort -u /tmp/closure.list -o /tmp/closure.list \
 && grep -v -E '^/usr/local/' /tmp/closure.list > /tmp/closure.deps \
 && tar -cf /tmp/closure.tar -T /tmp/closure.deps \
 && tar -xf /tmp/closure.tar -C /rootfs \
 && rm -f /tmp/dynload.list /tmp/mod.err /tmp/ext.list /tmp/closure.list \
          /tmp/closure.deps /tmp/closure.err /tmp/closure.tar

# Ce qu'aucune cloture ne voit, parce que ce n'est pas une dependance ELF :
#   /usr/lib/ossl-modules  fournisseurs OpenSSL, charges par dlopen
#   /etc/ssl/certs         magasin de CA (hooks SMTP/LDAP/IMAP en TLS)
#   /usr/share/zoneinfo    fuseaux pour zoneinfo et musl (le paquet tzdata de
#                          PyPI couvre deja dateutil)
RUN mkdir -p /rootfs/usr/local/bin /rootfs/usr/local/lib /rootfs/usr/lib \
             /rootfs/sbin /rootfs/etc/ssl/certs /rootfs/etc/radicale /rootfs/usr/share \
 && cp -a /usr/local/bin/python3.15 /rootfs/usr/local/bin/ \
 && ln -s python3.15 /rootfs/usr/local/bin/python3 \
 && cp -a /usr/local/lib/libpython3.15.so.1.0 /rootfs/usr/local/lib/ \
 && cp -a /usr/local/lib/python3.15 /rootfs/usr/local/lib/ \
 && cp -a /usr/lib/ossl-modules /rootfs/usr/lib/ \
 && cp /sbin/tini-static /rootfs/sbin/tini \
 && cp -a /usr/share/zoneinfo /rootfs/usr/share/ \
 && cp /etc/ssl/certs/ca-certificates.crt /rootfs/etc/ssl/certs/ \
 && ln -s certs/ca-certificates.crt /rootfs/etc/ssl/cert.pem \
 && grep -E '^(root|nobody|radicale):' /etc/passwd > /rootfs/etc/passwd \
 && grep -E '^(root|nobody|radicale):' /etc/group > /rootfs/etc/group

COPY config/config /rootfs/etc/radicale/config
RUN chmod 0644 /rootfs/etc/radicale/config

# Preuve au build, pas au premier demarrage : dans /rootfs tel qu'il sera
# publie, l'interpreteur charge TLS, le XML, zlib, bcrypt, les fuseaux, et
# chaque module de Radicale que la configuration par defaut et ses variantes
# courantes (htpasswd, http_x_remote_user, rights from_file, web interne)
# chargent. Puis Radicale valide la configuration livree.
RUN chroot /rootfs /usr/local/bin/python3 -I -B -c ' \
import ssl, hashlib, zlib, pyexpat, json, zoneinfo, importlib, ctypes; \
import xml.etree.ElementTree as ET; import defusedxml.ElementTree; \
import bcrypt, vobject, dateutil.tz, passlib.hash; \
h = bcrypt.hashpw(b"x", bcrypt.gensalt(4)); assert bcrypt.checkpw(b"x", h); \
s5 = passlib.hash.sha512_crypt.using(rounds=5000); assert s5.verify("x", s5.hash("x")); \
z = zoneinfo.ZoneInfo("Europe/Paris"); \
ssl.create_default_context(); \
mods = ["radicale.app", "radicale.server", "radicale.pathutils", "radicale.auth.htpasswd", "radicale.auth.denyall", \
        "radicale.auth.none", "radicale.auth.remote_user", "radicale.auth.http_x_remote_user", \
        "radicale.auth.http_remote_user", "radicale.auth.imap", "radicale.rights.owner_only", \
        "radicale.rights.owner_write", "radicale.rights.from_file", "radicale.rights.authenticated", \
        "radicale.storage.multifilesystem", "radicale.web.internal", "radicale.web.none", \
        "radicale.hook.none", "radicale.hook.email", "radicale.sharing.none", "radicale.sharing.csv", \
        "radicale.sharing.files"]; \
[importlib.import_module(m) for m in mods]; \
import radicale; print("python", __import__("sys").version.split()[0], "| openssl", ssl.OPENSSL_VERSION.split()[1], \
      "| radicale", radicale.VERSION, "| bcrypt", bcrypt.__version__, "|", len(mods), "modules OK")' \
 && chroot /rootfs /usr/local/bin/python3 -I -B -c ' \
import radicale.config as c; \
cfg = c.load([("/etc/radicale/config", False)]); \
assert cfg.get("auth", "type") == "htpasswd"; \
print("configuration livree valide")'

# --- Final : FROM scratch -----------------------------------------------
FROM scratch

ARG RADICALE_VERSION
# image.licenses decrit le logiciel embarque : Radicale (GPL-3.0-or-later),
# CPython (PSF-2.0), bcrypt (Apache-2.0), vobject (Apache-2.0), libpass
# (BSD-3-Clause), tini (MIT). Ce depot lui-meme est en Apache-2.0.
LABEL org.opencontainers.image.title="radicale-hardened" \
      org.opencontainers.image.description="Radicale ${RADICALE_VERSION} hardened (Tier Platine: FROM scratch, Go init, tini PID 1)" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.version="${RADICALE_VERSION}" \
      org.opencontainers.image.source="https://github.com/jbsky/radicale-hardened" \
      org.opencontainers.image.licenses="GPL-3.0-or-later AND PSF-2.0 AND Apache-2.0 AND BSD-3-Clause AND MIT" \
      security.hardening.tier="platine" \
      security.hardening.features="from-scratch,go-init,tini-pid1,zero-shell,non-root,read-only-rootfs,cosign-signed,sbom,slsa-provenance" \
      versions="radicale=${RADICALE_VERSION}"

COPY --link --from=prep /rootfs/ /
COPY --link --from=gobuilder /init /usr/local/bin/init

RUN ["/usr/local/bin/init", "--setup-dirs"]

ENV PATH="/usr/local/bin:/sbin" \
    LANG=C.UTF-8

USER 5232:5232
WORKDIR /var/lib/radicale
EXPOSE 5232

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD ["/usr/local/bin/init", "--healthcheck"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/init"]
