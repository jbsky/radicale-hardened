// Radicale hardened init -- entrypoint, healthcheck et preparation des
// repertoires, dans un binaire statique : l'image n'a pas de shell.
//
// Usage :
//
//	init --setup-dirs       cree le stockage et /tmp (RUN du stage final)
//	init --healthcheck      OPTIONS / sur le premier `hosts`, exit 0/1
//	init [ARGS...]          entrypoint : pre-verifications puis exec Radicale
//	init CMD [ARGS...]      exec directe de CMD (python3 -c ..., par exemple)
package main

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	radicaleUID   = 5232
	radicaleGID   = 5232
	pythonBin     = "/usr/local/bin/python3"
	defaultConfig = "/etc/radicale/config"
	// Valeurs par defaut de Radicale lui-meme (radicale/config.py), pour une
	// option que le fichier de configuration ne mentionne pas.
	defaultHosts    = "localhost:5232"
	defaultStorage  = "/var/lib/radicale/collections"
	defaultHtpasswd = "/etc/radicale/users"
	defaultAuthType = "denyall"
)

// pythonArgs : -I isole l'interpreteur (ni PYTHON* de l'environnement, ni
// site utilisateur, ni repertoire courant dans sys.path) ; -I faisant aussi
// ignorer PYTHONDONTWRITEBYTECODE et PYTHONUNBUFFERED, leurs equivalents
// passent en options : -B (aucun .pyc ecrit, le rootfs est en lecture seule)
// et -u (journaux non tamponnes, visibles tout de suite dans `logs`).
var pythonArgs = []string{pythonBin, "-I", "-B", "-u", "-m", "radicale"}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--setup-dirs":
			if err := setupDirs(); err != nil {
				fmt.Fprintf(os.Stderr, "[init][ERROR] setup-dirs: %v\n", err)
				os.Exit(1)
			}
			return
		case "--healthcheck":
			os.Exit(healthcheck())
		}
	}
	if err := entrypoint(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "[init][ERROR] %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// Setup directories -- appele au build, la ou il n'y a plus de shell pour un
// mkdir. Le stockage est ensuite masque par le volume en production : ce qui
// compte alors est le proprietaire du repertoire de l'hote, que l'entrypoint
// verifie par une ecriture reelle.
// ---------------------------------------------------------------------------

func setupDirs() error {
	dirs := []struct {
		path string
		mode os.FileMode
		uid  int
		gid  int
	}{
		{"/var/lib/radicale", 0o755, 0, 0},
		{defaultStorage, 0o750, radicaleUID, radicaleGID},
		// os.ModeSticky, pas 0o1000 : os.Chmod ne traduit que les bits
		// speciaux de Go (un 0o1777 litteral donne un /tmp sans sticky).
		{"/tmp", os.ModeSticky | 0o777, 0, 0},
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d.path, d.mode); err != nil {
			return fmt.Errorf("mkdir %s: %w", d.path, err)
		}
		// MkdirAll passe par l'umask : le mode est repose explicitement.
		if err := os.Chmod(d.path, d.mode); err != nil {
			return fmt.Errorf("chmod %s: %w", d.path, err)
		}
		if err := os.Chown(d.path, d.uid, d.gid); err != nil {
			return fmt.Errorf("chown %s: %w", d.path, err)
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Configuration -- lecture minimale du format de Radicale (configparser) :
// sections, `cle = valeur` ou `cle: valeur`, commentaires # et ; en debut de
// ligne, lignes de continuation indentees. Seules quatre options sont lues,
// celles que l'init doit verifier avant de lancer Radicale.
// ---------------------------------------------------------------------------

type config map[string]map[string]string

func (c config) get(section, option, fallback string) string {
	if s, ok := c[section]; ok {
		if v, ok := s[option]; ok && v != "" {
			return v
		}
	}
	return fallback
}

func (c config) set(section, option, value string) {
	if c[section] == nil {
		c[section] = map[string]string{}
	}
	c[section][option] = value
}

func parseConfig(r io.Reader) (config, error) {
	c := config{}
	section, last := "", ""
	sc := bufio.NewScanner(r)
	n := 0
	for sc.Scan() {
		n++
		raw := sc.Text()
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		// Continuation : configparser rattache une ligne indentee a la valeur
		// precedente.
		if raw[0] == ' ' || raw[0] == '\t' {
			if section != "" && last != "" {
				c[section][last] = strings.TrimSpace(c[section][last] + " " + line)
				continue
			}
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			if c[section] == nil {
				c[section] = map[string]string{}
			}
			last = ""
			continue
		}
		if section == "" {
			return nil, fmt.Errorf("ligne %d : option hors de toute section", n)
		}
		i := strings.IndexAny(line, "=:")
		if i <= 0 {
			return nil, fmt.Errorf("ligne %d : « %s » n'est pas de la forme cle = valeur", n, line)
		}
		last = strings.ToLower(strings.TrimSpace(line[:i]))
		c[section][last] = strings.TrimSpace(line[i+1:])
	}
	return c, sc.Err()
}

// configPath suit la meme priorite que Radicale : --config sur la ligne de
// commande, sinon RADICALE_CONFIG, sinon /etc/radicale/config. Un chemin
// prefixe de « ? » est facultatif pour Radicale ; il l'est aussi ici.
func configPath(args []string) (path string, optional bool) {
	path = env("RADICALE_CONFIG", defaultConfig)
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--config" || a == "-C":
			if i+1 < len(args) {
				path = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "--config="):
			path = strings.TrimPrefix(a, "--config=")
		}
	}
	// Plusieurs chemins separes par « : » : le dernier l'emporte chez
	// Radicale pour une option definie deux fois. Les quatre options lues
	// ici sont celles du dernier fichier qui existe.
	if strings.Contains(path, ":") {
		parts := strings.Split(path, ":")
		path = parts[len(parts)-1]
	}
	if strings.HasPrefix(path, "?") {
		return strings.TrimPrefix(path, "?"), true
	}
	return path, false
}

// applyOverrides reporte les options passees en ligne de commande
// (--storage-filesystem-folder=/data, --auth-type none...) : Radicale les
// fait primer sur le fichier, l'init doit donc verifier les memes valeurs.
func applyOverrides(c config, args []string) {
	watched := map[string][2]string{
		"--server-hosts":              {"server", "hosts"},
		"--server-ssl":                {"server", "ssl"},
		"--server-certificate":        {"server", "certificate"},
		"--server-key":                {"server", "key"},
		"--auth-type":                 {"auth", "type"},
		"--auth-htpasswd-filename":    {"auth", "htpasswd_filename"},
		"--storage-filesystem-folder": {"storage", "filesystem_folder"},
	}
	for i := 0; i < len(args); i++ {
		name, value, hasValue := strings.Cut(args[i], "=")
		target, ok := watched[name]
		if !ok {
			continue
		}
		if !hasValue {
			if i+1 >= len(args) {
				continue
			}
			value = args[i+1]
			i++
		}
		c.set(target[0], target[1], value)
	}
}

func loadConfig(args []string) (config, string, error) {
	path, optional := configPath(args)
	c := config{}
	f, err := os.Open(path)
	switch {
	case err == nil:
		defer f.Close()
		if c, err = parseConfig(f); err != nil {
			return nil, path, fmt.Errorf("%s illisible : %w", path, err)
		}
	case os.IsNotExist(err) && optional:
	case os.IsNotExist(err):
		return nil, path, fmt.Errorf("fichier de configuration absent : %s", path)
	default:
		return nil, path, fmt.Errorf("lecture %s : %w", path, err)
	}
	applyOverrides(c, args)
	return c, path, nil
}

func truthy(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "1", "yes", "true", "on":
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Healthcheck : OPTIONS / ne demande aucune authentification, et seul
// Radicale y repond avec un en-tete DAV qui annonce calendar-access -- ce
// qu'un connect TCP sur 5232 ne prouve pas.
// ---------------------------------------------------------------------------

func healthcheck() int {
	url := env("RADICALE_HEALTHCHECK_URL", "")
	if url == "" {
		c, _, err := loadConfig(nil)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[healthcheck] %v\n", err)
			return 1
		}
		if url, err = healthURL(c); err != nil {
			fmt.Fprintf(os.Stderr, "[healthcheck] %v\n", err)
			return 1
		}
	}
	client := &http.Client{
		Timeout: 10 * time.Second,
		// Certificat servi par Radicale lui-meme ([server] ssl) : on
		// interroge la boucle locale, le nom ne peut pas correspondre.
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, // #nosec G402 -- boucle locale
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	req, err := http.NewRequest(http.MethodOptions, url, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[healthcheck] %v\n", err)
		return 1
	}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[healthcheck] OPTIONS %s: %v\n", url, err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "[healthcheck] OPTIONS %s: HTTP %d\n", url, resp.StatusCode)
		return 1
	}
	if dav := resp.Header.Get("DAV"); !strings.Contains(dav, "calendar-access") {
		fmt.Fprintf(os.Stderr, "[healthcheck] OPTIONS %s: en-tete DAV inattendu %q\n", url, dav)
		return 1
	}
	return 0
}

// healthURL vise la premiere adresse de [server] hosts, ramenee sur la boucle
// locale quand Radicale ecoute sur toutes les interfaces.
func healthURL(c config) (string, error) {
	first := strings.TrimSpace(strings.Split(c.get("server", "hosts", defaultHosts), ",")[0])
	host, port, err := net.SplitHostPort(first)
	if err != nil {
		return "", fmt.Errorf("[server] hosts : %q illisible (%v)", first, err)
	}
	switch host {
	case "", "0.0.0.0", "localhost":
		host = "127.0.0.1"
	case "::":
		host = "::1"
	}
	scheme := "http"
	if truthy(c.get("server", "ssl", "false")) {
		scheme = "https"
	}
	return scheme + "://" + net.JoinHostPort(host, port) + "/", nil
}

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

func entrypoint(args []string) error {
	// Commande complete passee en argument (python3 -c ..., par exemple) :
	// exec directe, sans les pre-verifications du serveur.
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		return execProcess(args)
	}

	c, path, err := loadConfig(args)
	if err != nil {
		return err
	}
	if err := preflight(c); err != nil {
		return err
	}

	full := append(append([]string{}, pythonArgs...), args...)
	log("config=%s | stockage=%s | auth=%s | exec %s", path,
		c.get("storage", "filesystem_folder", defaultStorage),
		c.get("auth", "type", defaultAuthType), strings.Join(full, " "))
	return execProcess(full)
}

// preflight refuse de demarrer un serveur qui ne pourrait que repondre des
// erreurs : stockage en lecture seule, fichier htpasswd ou certificat absent.
// Radicale, lui, demarre quand meme et echoue requete par requete.
func preflight(c config) error {
	storage := c.get("storage", "filesystem_folder", defaultStorage)
	if !exists(storage) {
		return fmt.Errorf("stockage absent : %s -- monter un volume a cet endroit", storage)
	}
	if !writeOK(storage) {
		return fmt.Errorf("%s n'accepte pas d'ecriture pour l'uid %d -- le volume de l'hote "+
			"doit appartenir a %d:%d (chown -R %d:%d <repertoire>)",
			storage, os.Getuid(), radicaleUID, radicaleGID, radicaleUID, radicaleGID)
	}

	switch auth := c.get("auth", "type", defaultAuthType); auth {
	case "htpasswd":
		users := c.get("auth", "htpasswd_filename", defaultHtpasswd)
		if err := readable(users); err != nil {
			return fmt.Errorf("[auth] htpasswd : %v -- monter le fichier d'utilisateurs "+
				"(htpasswd -B) en lecture seule sur %s", err, users)
		}
		if st, err := os.Stat(users); err == nil && st.Mode().Perm()&0o004 != 0 {
			log("ATTENTION : %s est lisible par tous (mode %04o) -- chmod 640 et "+
				"groupe %d suffisent", users, st.Mode().Perm(), radicaleGID)
		}
	case "none":
		log("ATTENTION : [auth] type = none -- tout utilisateur est accepte sans mot de passe")
	}

	if truthy(c.get("server", "ssl", "false")) {
		for _, opt := range []string{"certificate", "key"} {
			p := c.get("server", opt, "")
			if p == "" {
				return fmt.Errorf("[server] ssl = true mais %s n'est pas renseigne", opt)
			}
			if err := readable(p); err != nil {
				return fmt.Errorf("[server] %s : %v", opt, err)
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Helpers -- vocabulaire commun des init.go du parc : env, exists, writeOK.
// ---------------------------------------------------------------------------

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// readable dit si un fichier s'ouvre reellement en lecture pour l'uid
// courant : un stat reussit sur un fichier 0600 d'un autre proprietaire.
func readable(path string) error {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("%s absent", path)
		}
		return fmt.Errorf("%s illisible pour l'uid %d (%v)", path, os.Getuid(), err)
	}
	f.Close()
	return nil
}

// writeOK dit si un repertoire accepte reellement une ecriture. mkdir + chmod
// + chown peuvent tous reussir sur un point de montage en lecture seule :
// seule une ecriture le prouve.
func writeOK(dir string) bool {
	tmp, err := os.CreateTemp(dir, ".write-test-*")
	if err != nil {
		return false
	}
	name := tmp.Name()
	tmp.Close()
	os.Remove(name)
	return true
}

func execProcess(args []string) error {
	bin := args[0]
	if !strings.HasPrefix(bin, "/") {
		var err error
		bin, err = exec.LookPath(bin)
		if err != nil {
			return fmt.Errorf("commande introuvable : %s", args[0])
		}
	}
	if err := os.Chdir(filepath.Dir(defaultStorage)); err != nil {
		return fmt.Errorf("chdir: %w", err)
	}
	return syscall.Exec(bin, args, os.Environ())
}

func log(format string, a ...any) {
	fmt.Printf("[init] "+format+"\n", a...)
}
