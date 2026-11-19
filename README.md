# Radicale Hardened

[![Build](https://github.com/jbsky/radicale-hardened/actions/workflows/build-push.yml/badge.svg)](https://github.com/jbsky/radicale-hardened/actions/workflows/build-push.yml)
[![Docker Hub](https://img.shields.io/docker/v/jbsky/radicale-hardened?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/jbsky/radicale-hardened)
[![Hardening](https://img.shields.io/badge/hardening-platine-blueviolet)](https://github.com/jbsky/radicale-hardened#hardening)

[Radicale](https://radicale.org) <!--v:radicale-hardened-->3.9.2<!--/v-->,
the CalDAV/CardDAV server, in a `FROM scratch` image: static Go init, `tini`
as PID 1, no shell, no package manager, no pip. Meant for a Podman deployment
on VyOS.

| | A plain `pip install radicale` image | This image |
|---|---|---|
| Base | Alpine or Debian, with a shell | `FROM scratch` |
| Shell, package manager, pip | yes | no |
| User | often root | `5232:5232` |
| Python dependencies | resolved at build time, unpinned | lockfile with sha256 (`pip --require-hashes`) |
| bcrypt | prebuilt wheel | compiled here from its source archive, crates pinned by `Cargo.lock` |
| Radicale release | taken as is | PyPI Trusted Publishing attestation verified (`version-watch`) |
| Authentication by default | Radicale's `denyall` | htpasswd file required, refused at startup if missing |
| Tested under `cap_drop: ALL`, read-only, `no-new-privileges` | -- | yes (`scripts/test.sh`) |

## What is built

| Component | Origin | Verification |
|---|---|---|
| Radicale | wheel from PyPI (pure Python: the wheel is the source) | sha256 pinned in `versions.json`, written by `version-watch` only after verifying the PyPI attestation (publisher `Kozea/Radicale`) |
| Python dependencies (vobject, defusedxml, libpass, dateutil, pytz, six, tzdata) | `py3-none-any` wheels from PyPI | sha256 pinned in [`requirements.txt`](requirements.txt), `pip check` at build |
| bcrypt | source archive from PyPI, Rust module compiled in the `pybuild` stage | sha256 pinned; `cargo fetch --locked`, then an **offline** build; the build fails if the module is not BIND_NOW + RELRO with a non-executable stack |
| CPython | official `python:3.15-alpine` image (built from source on Alpine) | digest pinned, followed daily by `base-watch` |
| OpenSSL, expat, libffi, musl | Alpine packages (a floor) | scanned on the `prep` stage |
| init | static Go, `CGO_ENABLED=0` | `go vet` + `go test` |

The Python runtime is the official image's, as in suricata-hardened: it ships
the current minor without waiting for an Alpine repackaging. The interpreter
is trimmed (no pip, ensurepip, venv, tkinter, idlelib, sqlite3, CPython's own
test extensions) and every C module of `lib-dynload` whose library is not
in the image is **deleted** rather than shipped broken: `_bz2`, `_lzma`,
`_sqlite3`, `_curses`, `readline`... Libraries are copied from a closure
resolved at build time (`lddtree`), never `/lib` or `/usr/lib` wholesale.

The `prep` stage then runs, **inside the final rootfs**, the interpreter with
TLS, XML, zlib, ctypes, bcrypt, SHA-512 crypt, time zones and every Radicale
module the default configuration and its common variants load, and has
Radicale validate the shipped configuration -- before anything is published.

### What is left out

| Removed | Consequence |
|---|---|
| `cheroot` | `[server] type = cheroot` is not available; the builtin server is used |
| `requests` | no `[auth] type = oauth2` |
| `pika` | no `[hook] type = rabbitmq` |
| `ldap3` / `python-ldap`, `pam` | `[auth] type = ldap` and `pam` fail at startup |
| `argon2-cffi` | no argon2 htpasswd entries: use bcrypt (`htpasswd -B`) or SHA-512 crypt |
| shell, pip | maintenance goes through the host (see [Running without a shell](#running-without-a-shell)) |

`scripts/test.sh` imports every Radicale module and requires the list of
those that fail to be exactly the one above.

## Hardening

Tier **platine** (OCI label `security.hardening.tier`): a `FROM scratch` image
with no shell and no package manager, a non-root user, a static Go init behind
`tini` as PID 1, and native code built with hardening flags.

- Non-root user `5232:5232`; tested under `cap_drop: ALL`, read-only rootfs
  and `no-new-privileges`. Port 5232 needs no capability.
- Python runs isolated: `python3 -I -B -u -m radicale` (no `PYTHON*`
  variables, no user site, no current directory on `sys.path`, no bytecode
  written).
- Authentication is **required**: the shipped configuration uses an htpasswd
  file, and the init refuses to start if it is missing or unreadable, with the
  fix in the message. Logins are cached (`cache_logins`) so a bcrypt check is
  not paid on every request; a failed login costs one second.
- XML is parsed through `defusedxml`: the test suite sends an external entity
  and checks it is never resolved.
- The init checks with a real write that the storage belongs to `5232:5232`,
  and refuses to start otherwise.
- Libraries copied from a dependency closure resolved at build time
  (`lddtree`), never `/lib` or `/usr/lib` wholesale.

## Tags

Every image is published under three tags: `latest` (last build of `main`),
the upstream version alone, and the upstream version followed by a **revision
counter**. The first two are **overwritten in place** on every rebuild (Alpine
update, CVE fix, configuration change), and the build they pointed to can no
longer be pulled by them. **In production, pin the tag that carries the
counter.**

<!-- BEGIN:tags (generated by CI -- do not edit by hand) -->
| Image | Upstream version | Immutable tag to pin |
|-------|------------------|----------------------|
| `jbsky/radicale-hardened` | `3.9.2` | `3.9.2.0` |
<!-- END:tags -->

This table, the versions quoted in the text and the tags in the examples are
rendered by `update-readme-tags.sh` ([hardened-ci](https://github.com/jbsky/hardened-ci))
after each publication: do not edit them by hand.

The counter counts the commits that touch the image inputs (the `revision`
list of [`.github/hardened-ci.json`](.github/hardened-ci.json)) since the last
upstream version change, and restarts at `0` with each new upstream version. A
commit that only touches `.github/` does not increment it.

`docker.io` and `ghcr.io` publish the same tags with the same digest, for
`linux/amd64` only for now. Each registry keeps the last six immutable tags of
an image, so that superseded builds do not stay pullable: move your pin
forward.

`version-watch` checks PyPI daily, verifies the attestation of the new
release, bumps `versions.json` and republishes, with no manual step. A release
that needs a dependency the lockfile does not provide is refused there, before
any commit.

## Usage

```yaml
services:
  radicale:
    image: jbsky/radicale-hardened:3.9.2.0
    read_only: true
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    tmpfs:
      - /tmp:nodev,nosuid,noexec,size=16m,mode=1777
    volumes:
      - ./collections:/var/lib/radicale/collections
      - ./users:/etc/radicale/users:ro
    ports:
      - "5232:5232"
```

Two things you cannot guess:

- **The storage must belong to `5232:5232`**: `chown -R 5232:5232 collections`.
  A named volume gets it from the image on first use.
- **The users file is mandatory.** Create it with `htpasswd -B -c users alice`
  (bcrypt), then `chown root:5232 users && chmod 640 users`. The init logs a
  warning if it is world-readable. `htpasswd -5` (SHA-512 crypt) works too.

The shipped configuration ([`config/config`](config/config)) listens on
`0.0.0.0:5232` and `[::]:5232`, stores collections in
`/var/lib/radicale/collections`, and lets each user see only their own
collections (`owner_only`). To change it, mount your own file on
`/etc/radicale/config` (or point `RADICALE_CONFIG` elsewhere): an option it
does not set takes **Radicale's** default, not the shipped one. Options can
also be passed as arguments, e.g. `--logging-level=debug`. The healthcheck
reads the same file to find the port; behind a TLS listener (`[server] ssl`)
it switches to HTTPS on its own.

TLS is best terminated by a reverse proxy (nginx-hardened, traefik-hardened,
haproxy-hardened). If Radicale serves it itself, mount the certificate and the
key and set `[server] ssl = True`: the init checks both are readable.

### VyOS

```
set container name radicale image 'docker.io/jbsky/radicale-hardened:3.9.2.0'
set container name radicale memory '256'
set container name radicale port caldav source '5232'
set container name radicale port caldav destination '5232'
set container name radicale volume collections source '/config/containers/radicale/collections'
set container name radicale volume collections destination '/var/lib/radicale/collections'
set container name radicale volume users source '/config/containers/radicale/users'
set container name radicale volume users destination '/etc/radicale/users'
set container name radicale volume users mode 'ro'
```

`/config/containers/radicale/collections` must belong to `5232:5232`, and
`users` to `root:5232` in mode `640`.

## Running without a shell

- **Adding a user**: edit the htpasswd file on the host (`htpasswd -B users bob`).
  Radicale rereads it at each login, no restart needed -- with two caveats. A
  single-file bind mount follows the inode: a tool that *replaces* the file
  (most editors) leaves the container on the old copy until it restarts. And
  a successful login stays cached for 15 minutes (`cache_logins`): a removed
  user or a changed password is fully effective after that delay, or at once
  after a restart. Without `htpasswd` on the host, the image can hash a
  password:
  `podman run --rm --entrypoint /usr/local/bin/python3 jbsky/radicale-hardened:3.9.2.0 -I -c 'import bcrypt, getpass; print(bcrypt.hashpw(getpass.getpass().encode(), bcrypt.gensalt()).decode())'`
- **Verifying the storage**: `podman exec radicale /usr/local/bin/init --verify-storage`
  runs `radicale --verify-storage` with the container's configuration.
- **Backups**: the collections are plain `.ics` / `.vcf` files; copy the
  directory from the host.

## Build and test

```bash
make build   # build args come from versions.json
make test    # scripts/test.sh: read-only, cap_drop ALL, no-new-privileges
make check   # versions.json checks, gofmt, go vet, go test
make scan    # Trivy, HIGH and CRITICAL
```

`scripts/test.sh` checks the absence of shell and pip, the user, the import of
every Radicale module, the init's refusals (no users file, read-only storage),
bcrypt and SHA-512 logins, `owner_only`, CalDAV (calendar creation, event,
recurring occurrence found by a time-range `REPORT` in `Europe/Paris`) and
CardDAV, an XXE attempt, the absence of passwords in the logs, the web
interface, the read-only rootfs, persistence across a restart, and the
healthcheck.

Versions live only in [`versions.json`](versions.json): the Dockerfile has no
defaults, `make build` and CI pass them through `scripts/versions-build-args.py`,
and a bare `docker build` stops at the guard. Python dependencies live only in
[`requirements.txt`](requirements.txt), bcrypt's build tools in
[`requirements-build.txt`](requirements-build.txt), both with their sha256.

## Verification

Images are signed with [cosign](https://github.com/sigstore/cosign) (keyless,
GitHub OIDC) by the shared [hardened-ci](https://github.com/jbsky/hardened-ci)
pipeline. The certificate names that workflow and, in an extension, this
repository: the commands below require both.

```bash
# ghcr.io
cosign verify ghcr.io/jbsky/radicale-hardened:3.9.2.0 \
  --certificate-identity-regexp '^https://github.com/(jbsky/radicale-hardened|jbsky/hardened-ci)/' \
  --certificate-github-workflow-repository jbsky/radicale-hardened \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Docker Hub (the signature is stored on ghcr.io)
COSIGN_REPOSITORY=ghcr.io/jbsky/radicale-hardened \
  cosign verify docker.io/jbsky/radicale-hardened:3.9.2.0 \
  --certificate-identity-regexp '^https://github.com/(jbsky/radicale-hardened|jbsky/hardened-ci)/' \
  --certificate-github-workflow-repository jbsky/radicale-hardened \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Each published digest also carries a CycloneDX SBOM (the `prep` stage the
image is assembled from, plus its Go binaries), attested with cosign, and a
GitHub SLSA build provenance attestation. The pipeline lints, builds, scans the
`prep` stage with Trivy, tests the exact digest it is about to publish (image
manifest, dependency closure, functional tests), then promotes and signs it.
Base image digests follow upstream daily (`base-watch`), a fixable Alpine
package CVE triggers a rebuild (`cve-watch`), and the published image is
audited weekly (`security-audit`: Trivy, Grype, cosign). Audit status and
documented exceptions: [`SECURITY.md`](SECURITY.md).

## License

The contents of this repository (Dockerfile, `init.go`, scripts and CI) are
licensed under **Apache-2.0**, see [`LICENSE`](LICENSE). Copyright 2026 jbsky.

The software shipped in the image keeps its own license: **Radicale is under
GPL-3.0-or-later**, and stays so in the image; CPython is under PSF-2.0,
bcrypt and vobject under Apache-2.0, libpass under BSD-3-Clause, tini under
MIT. The two never mix: `init.go` is a separate program that executes the
Python interpreter without being linked to it or reusing Radicale's code.

Contributions: see [`CONTRIBUTING.md`](CONTRIBUTING.md); a `Signed-off-by` is
required.
