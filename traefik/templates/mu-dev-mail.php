<?php
/**
 * Plugin Name: Local mail routing
 * Description: Sends all outgoing mail to the local Mailpit container so that nothing leaves this machine.
 */

add_action(
	'phpmailer_init',
	function ( $phpmailer ) {
		$phpmailer->isSMTP();
		$phpmailer->Host        = 'mailpit';
		$phpmailer->Port        = 1025;
		$phpmailer->SMTPAuth    = false;
		$phpmailer->SMTPAutoTLS = false;
		$phpmailer->SMTPSecure  = '';
	}
);
