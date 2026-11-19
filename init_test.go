package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnv(t *testing.T) {
	const key = "RADICALE_INIT_TEST_VAR"
	if got := env(key, "default"); got != "default" {
		t.Errorf("env(%q) = %q, want default", key, got)
	}
	t.Setenv(key, "custom")
	if got := env(key, "default"); got != "custom" {
		t.Errorf("env(%q) = %q, want custom", key, got)
	}
}

func TestExists(t *testing.T) {
	dir := t.TempDir()
	present := filepath.Join(dir, "present")

	if exists(present) {
		t.Errorf("exists(%q) = true before file creation", present)
	}

	if err := os.WriteFile(present, nil, 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	if !exists(present) {
		t.Errorf("exists(%q) = false after file creation", present)
	}

	if exists(filepath.Join(dir, "absent")) {
		t.Errorf("exists() reported true for a path that was never created")
	}
}

func TestWriteOK(t *testing.T) {
	dir := t.TempDir()
	if !writeOK(dir) {
		t.Errorf("writeOK(%q) = false for a writable temp dir", dir)
	}
	if writeOK(filepath.Join(dir, "absent")) {
		t.Errorf("writeOK() = true for a missing directory")
	}
}

func TestParseConfig(t *testing.T) {
	in := `# commentaire
; autre commentaire
[Server]
hosts = 0.0.0.0:5232,
    [::]:5232
ssl: True

[auth]
type = htpasswd
htpasswd_filename=/run/secrets/users
`
	c, err := parseConfig(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct{ s, o, want string }{
		{"server", "hosts", "0.0.0.0:5232, [::]:5232"},
		{"server", "ssl", "True"},
		{"auth", "type", "htpasswd"},
		{"auth", "htpasswd_filename", "/run/secrets/users"},
		{"storage", "filesystem_folder", defaultStorage},
	}
	for _, tc := range cases {
		if got := c.get(tc.s, tc.o, defaultStorage); got != tc.want {
			t.Errorf("[%s] %s = %q, want %q", tc.s, tc.o, got, tc.want)
		}
	}
}

func TestParseConfigErrors(t *testing.T) {
	for _, in := range []string{"hosts = x\n", "[server]\nnot an option\n"} {
		if _, err := parseConfig(strings.NewReader(in)); err == nil {
			t.Errorf("parseConfig(%q) accepted invalid input", in)
		}
	}
}

func TestConfigPath(t *testing.T) {
	t.Setenv("RADICALE_CONFIG", "")
	cases := []struct {
		env  string
		args []string
		want string
		opt  bool
	}{
		{"", nil, defaultConfig, false},
		{"/env/config", nil, "/env/config", false},
		{"/env/config", []string{"--config", "/arg/config"}, "/arg/config", false},
		{"", []string{"--config=?/maybe"}, "/maybe", true},
		{"", []string{"-C", "/a:/b"}, "/b", false},
	}
	for _, tc := range cases {
		t.Setenv("RADICALE_CONFIG", tc.env)
		got, opt := configPath(tc.args)
		if got != tc.want || opt != tc.opt {
			t.Errorf("configPath(env=%q, %v) = %q,%v want %q,%v", tc.env, tc.args, got, opt, tc.want, tc.opt)
		}
	}
}

func TestApplyOverrides(t *testing.T) {
	c := config{}
	applyOverrides(c, []string{"--storage-filesystem-folder=/data", "--auth-type", "none", "--debug"})
	if got := c.get("storage", "filesystem_folder", ""); got != "/data" {
		t.Errorf("filesystem_folder = %q", got)
	}
	if got := c.get("auth", "type", ""); got != "none" {
		t.Errorf("auth type = %q", got)
	}
}

func TestHealthURL(t *testing.T) {
	cases := []struct {
		hosts, ssl, want string
	}{
		{"0.0.0.0:5232, [::]:5232", "", "http://127.0.0.1:5232/"},
		{"[::]:8080", "true", "https://[::1]:8080/"},
		{"192.0.2.10:5232", "", "http://192.0.2.10:5232/"},
		{"", "", "http://127.0.0.1:5232/"},
	}
	for _, tc := range cases {
		c := config{}
		if tc.hosts != "" {
			c.set("server", "hosts", tc.hosts)
		}
		c.set("server", "ssl", tc.ssl)
		got, err := healthURL(c)
		if err != nil || got != tc.want {
			t.Errorf("healthURL(%q) = %q, %v; want %q", tc.hosts, got, err, tc.want)
		}
	}
	c := config{}
	c.set("server", "hosts", "no-port")
	if _, err := healthURL(c); err == nil {
		t.Errorf("healthURL accepted a host without port")
	}
}

func TestPreflight(t *testing.T) {
	dir := t.TempDir()
	users := filepath.Join(dir, "users")
	c := config{}
	c.set("storage", "filesystem_folder", dir)
	c.set("auth", "type", "htpasswd")
	c.set("auth", "htpasswd_filename", users)

	if err := preflight(c); err == nil || !strings.Contains(err.Error(), "absent") {
		t.Errorf("preflight without users file: %v", err)
	}
	if err := os.WriteFile(users, []byte("alice:x\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := preflight(c); err != nil {
		t.Errorf("preflight with users file: %v", err)
	}
	c.set("storage", "filesystem_folder", filepath.Join(dir, "absent"))
	if err := preflight(c); err == nil {
		t.Errorf("preflight accepted a missing storage folder")
	}
	c.set("storage", "filesystem_folder", dir)
	c.set("server", "ssl", "yes")
	if err := preflight(c); err == nil {
		t.Errorf("preflight accepted ssl without certificate")
	}
}

func TestHealthcheck(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodOptions {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("DAV", "1, 2, 3, calendar-access, addressbook, extended-mkcol")
	}))
	defer srv.Close()
	t.Setenv("RADICALE_HEALTHCHECK_URL", srv.URL+"/")
	if rc := healthcheck(); rc != 0 {
		t.Errorf("healthcheck() = %d on a Radicale-like server", rc)
	}

	other := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer other.Close()
	t.Setenv("RADICALE_HEALTHCHECK_URL", other.URL+"/")
	if rc := healthcheck(); rc != 1 {
		t.Errorf("healthcheck() = %d on a server without DAV header", rc)
	}
}
