# Local WordPress dev environment

This repository is the tooling that runs every local WordPress site under
`~/dev`. Each site lives in `~/dev/<site>/`. This file is loaded in every
session started anywhere below `~/dev`, including inside a site or a theme.
`README.md` explains how each piece works and why. Read the matching section
there before changing a template or a script.

## Repositories

- `~/dev` tracks only the tooling: the scripts, `lib/` and `traefik/`. Every site directory is git-ignored.
- A theme in `~/dev/<site>/src/wp-content/themes/<slug>` is its own repository at `github.com/redandbluefi/<slug>`. Theme work is committed there.
- The other top-level directories that hold no `docker-compose.yaml` (`slackbot`, `rnb-claude-marketplace` and so on) are unrelated projects with their own repositories.

## How the stack fits together

```
browser ─https─> traefik (:80/:443, shared) ─http─> <site>-nginx ─fastcgi─> <site>-app (PHP-FPM)
                                                                               │
                                     <site>-db (MariaDB 11.8) <────────────────┘
<site>-app / wp-setup / wp-cli ─http_proxy─> egress-proxy (Squid, host network) ─> internet
```

Shared stack, `traefik/docker-compose.yaml`, one per machine, `restart: unless-stopped`:

- `traefik` terminates TLS with mkcert certificates listed in `traefik/dynamic_conf.yaml` (stored in `traefik/certs/<site>-cert.pem`) and routes by host name through Docker labels on the external `web-proxy` network. Dashboard at <http://127.0.0.1:8080>.
- `egress-proxy` carries all outbound HTTP(S) from the site containers on `host.docker.internal:3128`. A VPN (FortiClient) cuts Docker bridge networks off from the internet, so outbound requests rely on this proxy. Access log: `docker exec egress-proxy tail -f /var/log/squid/access.log`.

Per site, `<site>/docker-compose.yaml`, `restart: "no"`, so sites are down after a reboot:

| Service | Container | Role |
|---|---|---|
| `mysql` | `<site>-db` | MariaDB, volume `<site>_db_data`. DB `wordpress`, user/pass `wordpress`/`wordpress`, root pass `rootpassword`. |
| `wordpress` | `<site>-app` | PHP 8.4 FPM, `./src` mounted at `/var/www/html`. Only container with `WP_DEBUG`. |
| `nginx` | `<site>-nginx` | Server block from `nginx/nginx.conf`, includes from `nginx/configs/`. Missing uploads redirect to `PROD_DOMAIN`. |
| `mailpit` | `<site>-mail` | Catches all outgoing mail, inbox at `https://mail.<domain>`. |
| `wp-setup` | `<site>-setup` | One-shot on every `up`: installs WordPress if missing, then exits. Exiting is its normal state. |
| `wp-cli` | none | Profile `cli`, started on demand only. |

`WP_HOME`, `WP_SITEURL`, the proxy constants and the debug flags come from
`WORDPRESS_CONFIG_EXTRA` in the compose file. A multisite network omits
`WP_HOME` and `WP_SITEURL`.

## Site layout and generated files

```
<site>/
  site.conf                 the site's facts: SITE_NAME, DOMAIN, PROD_DOMAIN, NETWORK_TYPE, THEME_SLUG
  .env                      per-site env vars for getenv(), hand-edited, never regenerated
  docker-compose.yaml       generated
  nginx/nginx.conf          generated
  nginx/configs/*.conf      generated
  php/php-*-dev.ini         generated
  src/                      WordPress root
    composer.json           generated
    wp-content/mu-plugins/dev-*.php   generated
    wp-content/debug.log
```

Generated files are rendered by `lib/site.sh` from `traefik/templates/` and
`site.conf`, and the next `--update` overwrites them. Make lasting changes in
the source:

- A change for every site goes in `traefik/templates/`, then `./create-site.sh --update --all`.
- A change for one site goes in its `site.conf`, then `./create-site.sh --update <site>`.
- A secret or API key for one site goes in `<site>/.env`.

Read the domain from `site.conf`. Most sites use `.test`, some older ones `.dev`.
Admin login on every site: `admin` / `password`.

## Commands

From `~/dev`:

| Command | Agent can run it? |
|---|---|
| `./create-site.sh --update <site> --dry-run` | Yes. Prints the diff, writes nothing. |
| `./create-site.sh --update --all --dry-run` | Yes. |
| `./create-site.sh --update <site> --yes` | Yes, after the user has seen the dry-run diff and agreed. |
| `./setup-theme.sh <site> <slug>` | Yes. Clones, installs, builds and activates. May ask for `sudo` when the themes directory is not writable. |
| `./create-site.sh [--multisite[=subdomain\|subdirectory]]` | No: interactive prompts and `sudo`. Ask the user to run it with `! ./create-site.sh`. |
| `./delete-site.sh <site>` | No: destructive and interactive. Only the user runs it. |
| `cd traefik && docker compose up -d` | Yes. Starts the shared stack. |

From `~/dev/<site>`:

```sh
docker compose up -d                                  # start the site
docker compose up -d --force-recreate                 # apply compose, .env or ini changes
docker compose ps -a                                  # state, including the exited wp-setup
docker compose logs --tail=100 <service>              # wordpress, nginx, mysql, wp-setup
docker compose run --rm wp-cli wp <command>           # all WP-CLI
docker compose exec mysql mariadb -uwordpress -pwordpress wordpress   # SQL shell
tail -n 100 src/wp-content/debug.log                  # PHP errors and notices
```

WP-CLI runs only inside the `wp-cli` container. A host `wp` binary has no
database connection.

From a theme directory: `pnpm run build`, `pnpm run dev` (watch),
`composer install`.

## Diagnosing

Work down the request path and stop at the first broken link:

1. **Name resolution.** `getent hosts <domain>` returns `127.0.0.1`. Each subsite of a subdomain network needs its own `/etc/hosts` line.
2. **Shared stack.** `docker ps --filter name=traefik --filter name=egress-proxy` shows both up. If traefik is up but `docker port traefik` is empty, it lost the `web-proxy` network, and the fix to propose is `cd ~/dev/traefik && docker compose up -d --force-recreate traefik`.
3. **TLS.** A certificate error means the domain is missing from `traefik/dynamic_conf.yaml` or its PEM files are missing from `traefik/certs/`. Traefik reloads that file by itself.
4. **Site containers.** `docker compose ps -a` in the site. A 404 from Traefik means nginx is not running. A 502 from nginx means `wordpress` is not running.
5. **Install.** `docker compose logs wp-setup`. It waits two minutes for `wp-config.php` and then gives up.
6. **PHP.** `src/wp-content/debug.log`, then `docker compose logs wordpress`.
7. **Outbound requests** (WP Migrate licence, plugin installs, Composer, cURL error 7 in `debug.log`): check `egress-proxy` is up and read its access log. A site whose compose file has no `http_proxy` predates the proxy and needs `--update`.
8. **File permissions** ("Unable to overwrite destination file", acf-json not saving): files must be group `www-data` (gid 33) and group-writable. The fix commands are in the README troubleshooting section.

The README's Troubleshooting section covers more cases.

## Ask before

These change shared state or cannot be undone, so confirm with the user first:

- `docker compose down -v`, `docker volume rm`, or anything else that drops a `<site>_db_data` volume.
- `./delete-site.sh`, and removing any site directory.
- Editing `/etc/hosts`, and any `sudo` command.
- `--update` without `--dry-run` first, especially `--all`.
- `wp search-replace`, `wp db import`, `wp db reset` and WP Migrate pulls.
- Restarting or recreating `traefik` or `egress-proxy`, which affects every site at once.

Secrets live in `traefik/templates/auth.json`, `traefik/templates/licenses.env`,
each `<site>/.env` and each theme's `auth.json`. Use them by path and keep
their values out of output and commits.
