#!/bin/bash
# Tests fonctionnels de radicale-hardened, sur un conteneur lance avec les
# contraintes de production (lecture seule, cap_drop ALL, no-new-privileges).
#
#   scripts/test.sh [image]
set -eu

IMAGE="${1:-localhost/radicale-hardened:latest}"
NAME="radicale-test-$$"
PORT="${RADICALE_TEST_PORT:-15232}"
BASE="http://127.0.0.1:${PORT}"
WORK="$(mktemp -d)"
PASS=0
FAIL=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

cleanup() {
    docker rm -f "${NAME}" "${NAME}-ko" > /dev/null 2>&1 || true
    docker volume rm "${NAME}-data" > /dev/null 2>&1 || true
    rm -rf "${WORK}"
}
trap cleanup EXIT

# Code HTTP d'une requete : code <methode> <url> [options curl...]
code() {
    local m="$1" u="$2"
    shift 2
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X "$m" "$@" "$u" || true
}

# Verifie qu'une valeur vaut l'attendu : expect <libelle> <attendu> <obtenu>
expect() {
    if [ "$3" = "$2" ]; then pass "$1 ($3)"; else fail "$1 : $3 (attendu $2)"; fi
}

py() { docker run --rm --entrypoint /usr/local/bin/python3 "${IMAGE}" -I -B "$@"; }

echo ""
echo "=== radicale-hardened -- ${IMAGE} ==="

echo ""
echo "--- Image ---"
if docker run --rm --entrypoint /bin/sh "${IMAGE}" -c true > /dev/null 2>&1; then
    fail "aucun /bin/sh dans l'image"
else
    pass "aucun /bin/sh dans l'image"
fi
user="$(docker image inspect -f '{{.Config.User}}' "${IMAGE}")"
expect "USER" "5232:5232" "${user}"
tier="$(docker image inspect -f '{{index .Config.Labels "security.hardening.tier"}}' "${IMAGE}")"
expect "label security.hardening.tier" "platine" "${tier}"
if py -c 'import pip' > /dev/null 2>&1; then fail "pip absent de l'image"; else pass "pip absent de l'image"; fi

# Chaque module de Radicale s'importe, sauf ceux dont la dependance n'est
# volontairement pas embarquee (cf. README, « What is left out »). Un module
# de plus dans cette liste est une regression, un de moins une dependance
# arrivee sans decision : les deux echouent.
broken="$(py -c '
import importlib, pkgutil, radicale
bad = []
for m in pkgutil.walk_packages(radicale.__path__, "radicale."):
    try:
        importlib.import_module(m.name)
    except Exception as e:
        bad.append(m.name)
print(" ".join(sorted(bad)))' 2>&1 || echo "python en echec")"
expected="radicale.auth.oauth2 radicale.hook.rabbitmq radicale.server_cheroot"
expect "modules non importables = dependances non embarquees" "${expected}" "${broken}"

echo ""
echo "--- Refus de demarrer (init) ---"
docker volume create "${NAME}-data" > /dev/null
out="$(docker run --name "${NAME}-ko" --read-only --cap-drop ALL \
    -v "${NAME}-data:/var/lib/radicale/collections" "${IMAGE}" 2>&1 || true)"
docker rm -f "${NAME}-ko" > /dev/null 2>&1 || true
if echo "${out}" | grep -q 'htpasswd.*absent'; then
    pass "sans fichier d'utilisateurs : refus explicite"
else
    fail "sans fichier d'utilisateurs : ${out}"
fi

# Le fichier d'utilisateurs : bcrypt (htpasswd -B) et SHA-512 crypt, hashes
# par l'image elle-meme -- c'est aussi la preuve que bcrypt et libpass y
# fonctionnent.
PW_ALICE="alice-$$-${RANDOM}"
PW_BOB="bob-$$-${RANDOM}"
py -c '
import sys, bcrypt
from passlib.hash import sha512_crypt
print("alice:" + bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())
print("bob:" + sha512_crypt.using(rounds=5000).hash(sys.argv[2]))' "${PW_ALICE}" "${PW_BOB}" > "${WORK}/users"
chmod 0644 "${WORK}/users"
# shellcheck disable=SC2016 # prefixes de hash ($2b$, $6$), pas des expansions
if grep -q -F 'alice:$2b$' "${WORK}/users" && grep -q -F 'bob:$6$' "${WORK}/users"; then
    pass "htpasswd genere dans l'image (bcrypt + sha512_crypt)"
else
    fail "htpasswd : $(cat "${WORK}/users")"
fi

out="$(docker run --name "${NAME}-ko" --read-only --cap-drop ALL \
    --tmpfs /var/lib/radicale/collections:ro \
    -v "${WORK}/users:/etc/radicale/users:ro" "${IMAGE}" 2>&1 || true)"
docker rm -f "${NAME}-ko" > /dev/null 2>&1 || true
if echo "${out}" | grep -q "n'accepte pas d'ecriture"; then
    pass "stockage en lecture seule : refus explicite"
else
    fail "stockage en lecture seule : ${out}"
fi

echo ""
echo "--- Demarrage (lecture seule, cap_drop ALL, no-new-privileges) ---"
start() {
    docker run -d --name "${NAME}" \
        --read-only --tmpfs /tmp:nodev,nosuid,noexec,size=16m,mode=1777 \
        --cap-drop ALL --security-opt no-new-privileges:true \
        -v "${NAME}-data:/var/lib/radicale/collections" \
        -v "${WORK}/users:/etc/radicale/users:ro" \
        -p "127.0.0.1:${PORT}:5232" \
        "${IMAGE}" > /dev/null
    for _ in $(seq 60); do
        if [ "$(code OPTIONS "${BASE}/")" = "200" ]; then return 0; fi
        sleep 1
    done
    return 1
}
if start; then
    pass "OPTIONS / repond 200"
else
    fail "Radicale ne repond pas"
    docker logs "${NAME}" 2>&1 | tail -30
    exit 1
fi

dav="$(curl -s -I -X OPTIONS --max-time 5 "${BASE}/" | tr -d '\r' | sed -n 's/^DAV: //Ip')"
if echo "${dav}" | grep -q 'calendar-access' && echo "${dav}" | grep -q 'addressbook'; then
    pass "en-tete DAV : CalDAV + CardDAV (${dav})"
else
    fail "en-tete DAV : ${dav}"
fi

echo ""
echo "--- Authentification ---"
A=(-u "alice:${PW_ALICE}")
B=(-u "bob:${PW_BOB}")
expect "PROPFIND sans authentification" 401 "$(code PROPFIND "${BASE}/alice/")"
expect "mauvais mot de passe" 401 "$(code PROPFIND "${BASE}/alice/" -u "alice:faux")"
expect "alice (bcrypt) : PROPFIND de son principal" 207 "$(code PROPFIND "${BASE}/alice/" "${A[@]}" -H 'Depth: 0')"
expect "bob (sha512_crypt) : PROPFIND de son principal" 207 "$(code PROPFIND "${BASE}/bob/" "${B[@]}" -H 'Depth: 0')"

echo ""
echo "--- CalDAV ---"
cat > "${WORK}/event.ics" <<'ICS'
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//radicale-hardened//test//EN
BEGIN:VEVENT
UID:test-event-1@radicale-hardened
DTSTAMP:20260101T000000Z
DTSTART;TZID=Europe/Paris:20261120T100000
DTEND;TZID=Europe/Paris:20261120T110000
SUMMARY:radicale-hardened smoke
RRULE:FREQ=WEEKLY;COUNT=3
END:VEVENT
END:VCALENDAR
ICS
expect "MKCALENDAR" 201 "$(code MKCALENDAR "${BASE}/alice/cal/" "${A[@]}")"
expect "PUT d'un evenement" 201 "$(code PUT "${BASE}/alice/cal/ev1.ics" "${A[@]}" -H 'Content-Type: text/calendar' --data-binary "@${WORK}/event.ics")"
if curl -s --max-time 5 "${A[@]}" "${BASE}/alice/cal/ev1.ics" | grep -q 'SUMMARY:radicale-hardened smoke'; then
    pass "GET de l'evenement"
else
    fail "GET de l'evenement"
fi
# La troisieme occurrence (4 decembre) n'existe que par la RRULE et le
# fuseau Europe/Paris : vobject, dateutil et tzdata travaillent ensemble.
cat > "${WORK}/report.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop><D:getetag/></D:prop>
  <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">
    <C:time-range start="20261204T000000Z" end="20261205T000000Z"/>
  </C:comp-filter></C:comp-filter></C:filter>
</C:calendar-query>
XML
if curl -s --max-time 10 "${A[@]}" -X REPORT -H 'Depth: 1' -H 'Content-Type: application/xml' \
        --data-binary "@${WORK}/report.xml" "${BASE}/alice/cal/" | grep -q '/alice/cal/ev1.ics'; then
    pass "REPORT time-range : occurrence recurrente trouvee (RRULE + fuseau)"
else
    fail "REPORT time-range : occurrence recurrente absente"
fi
expect "bob ne lit pas le calendrier d'alice (owner_only)" 403 "$(code PROPFIND "${BASE}/alice/cal/" "${B[@]}" -H 'Depth: 0')"

echo ""
echo "--- CardDAV ---"
mkcol='<?xml version="1.0"?><D:mkcol xmlns:D="DAV:" xmlns:CR="urn:ietf:params:xml:ns:carddav"><D:set><D:prop><D:resourcetype><D:collection/><CR:addressbook/></D:resourcetype></D:prop></D:set></D:mkcol>'
expect "MKCOL carnet d'adresses" 201 "$(code MKCOL "${BASE}/alice/contacts/" "${A[@]}" -H 'Content-Type: application/xml' --data-binary "${mkcol}")"
printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:test-card-1\r\nFN:Jane Test\r\nN:Test;Jane;;;\r\nEND:VCARD\r\n' > "${WORK}/card.vcf"
expect "PUT d'une vCard" 201 "$(code PUT "${BASE}/alice/contacts/c1.vcf" "${A[@]}" -H 'Content-Type: text/vcard' --data-binary "@${WORK}/card.vcf")"

echo ""
echo "--- Durcissement applicatif ---"
# defusedxml : une entite externe ne doit jamais etre resolue.
xxe='<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><D:propfind xmlns:D="DAV:"><D:prop><D:displayname>&e;</D:displayname></D:prop></D:propfind>'
body="$(curl -s --max-time 5 "${A[@]}" -X PROPFIND -H 'Depth: 0' -H 'Content-Type: application/xml' --data-binary "${xxe}" "${BASE}/alice/" || true)"
if echo "${body}" | grep -q 'radicale:x:5232'; then
    fail "XXE : /etc/passwd divulgue"
else
    pass "XXE refusee (entite externe non resolue)"
fi
if docker logs "${NAME}" 2>&1 | grep -q -F "${PW_ALICE}"; then
    fail "un mot de passe apparait dans les journaux"
else
    pass "aucun mot de passe dans les journaux"
fi

echo ""
echo "--- Interface web, persistance, processus ---"
if curl -s --max-time 5 "${BASE}/.web/" | grep -q '<title>Radicale Web Interface'; then
    pass "interface web servie (/.web/)"
else
    fail "interface web absente"
fi

hc="$(docker exec "${NAME}" /usr/local/bin/init --healthcheck > /dev/null 2>&1 && echo 0 || echo 1)"
expect "init --healthcheck" 0 "${hc}"
ids="$(docker exec "${NAME}" /usr/local/bin/python3 -I -c 'import os; print("%d:%d" % (os.getuid(), os.getgid()))')"
expect "Radicale tourne en" "5232:5232" "${ids}"
if docker exec "${NAME}" /usr/local/bin/python3 -I -c 'open("/usr/local/lib/x", "w")' > /dev/null 2>&1; then
    fail "rootfs en ecriture"
else
    pass "rootfs en lecture seule"
fi

docker restart "${NAME}" > /dev/null
ok=0
for _ in $(seq 60); do
    if [ "$(code OPTIONS "${BASE}/")" = "200" ]; then ok=1; break; fi
    sleep 1
done
if [ "${ok}" = 1 ] && curl -s --max-time 5 "${A[@]}" "${BASE}/alice/contacts/c1.vcf" | grep -q 'FN:Jane Test'; then
    pass "donnees conservees apres redemarrage (volume)"
else
    fail "donnees perdues apres redemarrage"
fi
expect "DELETE de l'evenement" 200 "$(code DELETE "${BASE}/alice/cal/ev1.ics" "${A[@]}")"

echo ""
echo "=== Resultat : ${PASS} reussis, ${FAIL} en echec ==="
[ "${FAIL}" -eq 0 ]
