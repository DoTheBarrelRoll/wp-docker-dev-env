<?php
/**
 * Plugin Name: Local network URLs
 * Description: Stores every new subsite on https, which the local wildcard certificate covers.
 */

add_filter(
	'wp_initialize_site_args',
	function ( $args, $site ) {
		// WordPress stores a new subsite on a subdomain network as http,
		// because in production a fresh subdomain has no certificate yet. Here
		// the mkcert certificate covers *.<domain> and Traefik serves nothing
		// but https, so the subsite is https from the first request.
		$url = untrailingslashit( 'https://' . $site->domain . $site->path );

		$args['options']['home']    = $url;
		$args['options']['siteurl'] = $url;

		return $args;
	},
	10,
	2
);
