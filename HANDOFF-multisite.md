# Handoff: WordPress multisite support in the scaffolding

Status: **not started**, deferred on 2026-08-25 by request. This is the research
and design, so the next session can start implementing instead of rediscovering.
Everything below was verified against the files, not recalled.

## Goal

Let `create-site.sh` scaffold a multisite network, both subdomain and
subdirectory, as well as it currently scaffolds a single site.

## What blocks it today

| # | Blocker | Where |
|---|---|---|
| 1 | `WP_HOME` and `WP_SITEURL` are hardcoded to the main domain | `traefik/templates/wp-template.yaml:22-23` |
| 2 | Traefik router matches one exact host, so subsites 404 at the proxy | `traefik/templates/wp-template.yaml:74` |
| 3 | nginx has no multisite rewrites, so subdirectory subsite admin and core assets 404 | `traefik/templates/nginx.conf` |
| 4 | Installer runs single-site `wp core install`; `/etc/hosts` only gets the main domain and `mail.` | `wp-template.yaml:134`, `create-site.sh:204` |

## What already works, do not redo it

- **TLS for subsites is covered.** `create-site.sh:135` issues the certificate
  for `$DOMAIN` *and* `*.$DOMAIN`, so subdomain networks need no certificate
  work at all.
- **The uploads production fallback survives.** It matches on the prefix
  `^~ /wp-content/uploads/`, which covers `uploads/sites/<id>/`, so per subsite
  media fallback keeps working unchanged.

## The one real design tension

`WP_HOME` and `WP_SITEURL` were added deliberately, so that a site keeps its
local URL right after a production database import. Multisite derives each
site's URL from the network tables, so those two constants force every subsite
onto the main domain and have to go.

The two features are mutually exclusive. For multisite the local-URL
convenience has to come from a `wp search-replace` after each pull instead.
Make this explicit in the README rather than quietly dropping the constants,
because the single-site behaviour is documented there as a feature.

Implication: `WORDPRESS_CONFIG_EXTRA` becomes conditional, so `create-site.sh`
has to strip those two lines from the template when a network type is chosen.

## Implementation hazard, think about this first

There is a chicken-and-egg problem. If `MULTISITE` is true in the compose
environment from the first boot, WordPress expects network tables that
`wp core multisite-install` has not created yet, and WP-CLI itself boots
WordPress before it can fix that.

I originally suggested `wp core multisite-install --skip-config` to keep
configuration in the compose file. **Prefer the opposite:** let WP-CLI own the
multisite constants by *not* passing `--skip-config`, so they land in
`wp-config.php` only once the network actually exists. `wp-config.php` persists
in `src/`, and the official image only generates it when absent, so WP-CLI's
edits survive. `WORDPRESS_CONFIG_EXTRA` keeps carrying `FS_METHOD` and the
debug constants.

Verified in the image, both flags exist:

```sh
docker run --rm wordpress:cli-php8.3 wp core multisite-install --help
# [--subdomains]   use subdomains instead of subdirectories
# [--base=<url-path>]
# [--skip-config]  don't add multisite constants to wp-config.php
```

`WP_ALLOW_MULTISITE` is only needed for the wp-admin conversion flow, not for
`wp core multisite-install`.

## Sketch of the changes

**Traefik rule** for subdomain networks, replacing the `Host()` rule:

```
traefik.http.routers.${SITE_NAME}.rule=Host(`${DOMAIN}`) || HostRegexp(`^.+\.${DOMAIN}$`)
```

Traefik v3 `HostRegexp` takes a Go regexp. Verify the mailpit router still wins
for `mail.${DOMAIN}`; router priority is by rule length, so check it rather than
assume, and set an explicit `priority` if it does not.

**nginx**, subdirectory networks. The WordPress-documented block is:

```nginx
if (!-e $request_filename) {
    rewrite /wp-admin$ $scheme://$host$uri/ permanent;
    rewrite ^(/[^/]+)?(/wp-.*) $2 last;
    rewrite ^(/[^/]+)?(/.*\.php) $2 last;
}
```

Note this uses `if (!-e ...)`, the same antipattern that was deliberately
removed from the uploads block in favour of `try_files`. Try to express it
without `if` first; if that fails, keep it and say why in a comment.

**nginx**, subdomain networks: widen `server_name` to `${DOMAIN} *.${DOMAIN}`.
It happens to work without this today, because the single server block is the
default server, but being explicit avoids a trap later.

**Installer**: `wp core multisite-install --url=https://${DOMAIN} [--subdomains]`
with the same title, admin user and `--skip-email` as now.

**Hosts entries**: hosts files have no wildcards, so every subdomain needs its
own line. Print the line to add whenever a subsite is created rather than
trying to manage it. Worth cross-referencing the LAN access discussion: a
dnsmasq wildcard would solve this properly, but the stock TP-Link AX1800
firmware cannot do it.

## Open questions

1. Does the WP Migrate plan cover multisite pulls? Verify, do not assume.
2. Should theme activation become `wp theme enable --network` for a network?
   `setup-theme.sh` currently runs `wp theme activate`.
3. Support both network types, or only subdomain? Subdomain is the smaller
   change and matches the wildcard certificate. Subdirectory needs the nginx
   rewrites and nothing else, so both are probably worth it.
4. Fourth prompt in `create-site.sh` versus a flag. There are already four
   prompts, so a fifth may be one too many.

## Test plan

Follow the pattern used for the earlier work: create a throwaway site, verify,
delete it with `delete-site.sh`, and confirm `traefik/dynamic_conf.yaml` comes
back byte-identical to a backup taken first.

Per network type:

- `wp site list` shows the network, and `wp site create --slug=sub` works.
- The main site and a subsite both return 200 over HTTPS through Traefik, using
  `curl --resolve` so no hosts entry is needed for the test.
- Subsite `wp-admin` loads, and its core assets under `wp-includes` load.
- `is_ssl()` is still true behind the proxy on a subsite.
- The uploads fallback still redirects for `uploads/sites/2/...`.
- Mailpit at `mail.$DOMAIN` still routes, meaning the widened rule did not
  swallow it.

## Environment gotchas that cost time before

- **Traefik cannot bind 80 and 443 while Local by Flywheel runs.** Its router
  nginx owns those ports. Quit Local first.
- **sudo needs a password in an agent session**, so `create-site.sh` cannot be
  run start to finish non-interactively. It stops at the ownership pass. A root
  container (`docker run --rm -v /home/miikka/dev:/work alpine ...`) can
  emulate that step for testing, and can delete uid 33 owned files.
- **FortiClient blackholes outbound TCP 443 from Docker bridges.** Port 80 from
  the same container to the same IP works, and the host is unaffected. Anything
  in a container that needs HTTPS fails while the VPN is up.
- **pnpm 11 fails `pnpm install`** in the themes with `ERR_PNPM_IGNORED_BUILDS`
  until build scripts are approved; `setup-theme.sh` handles it.
- **The `eternia` starter cannot build**, it git-ignores `blocks/` and
  `block-library/` and the gulp build needs the latter. Use a project theme.
- **Composer dist archives carry their own file modes**, which is why
  `setup-theme.sh` normalises `wp-content/plugins`. See PR 2.
