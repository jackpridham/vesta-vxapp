<?php
error_reporting(NULL);
$TAB = 'WEB';

// Main include
include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_domain_connections.php");

// Data
exec (VESTA_CMD."v-list-web-domains $user json", $output, $return_var);
$data = json_decode(implode('', $output), true);
$data = is_array($data) ? array_reverse($data,true) : array();
$vx_domain_connection_children = array();
foreach ($data as $domain => $details) {
    $parent = vx_domain_connection_child_parent($details);
    if ($parent !== '') $vx_domain_connection_children[$parent][] = $domain;
}
$ips = json_decode(shell_exec(VESTA_CMD.'v-list-sys-ips json'), true);

// Render page
render_page($user, $TAB, 'list_web');

// Back uri
$_SESSION['back'] = $_SERVER['REQUEST_URI'];
