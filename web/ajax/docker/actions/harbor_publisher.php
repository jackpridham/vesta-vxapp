<?php
$authentication_check_this_is_nested_script = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/form-elements.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose_package.php");

$action = isset($_POST['dataset']['publisher_action']) && !is_array($_POST['dataset']['publisher_action'])
    ? (string) $_POST['dataset']['publisher_action']
    : (isset($_POST['publisher_action']) && !is_array($_POST['publisher_action']) ? (string) $_POST['publisher_action'] : '');
if ($myvesta_logged_user === 'admin' || ($action !== 'rotate' && $action !== 'disable')) {
    echo __('Publisher action is unavailable.'); exit;
}
if (!isset($_POST['Yes']) && !isset($_POST['No'])) {
    echo myvesta_open_form('/ajax/docker/router.php');
    if ($action === 'rotate') echo myvesta_get_element('password', 'publisher_secret', '', __('New publisher credential'));
    echo myvesta_get_hidden_fields(array('harbor_publisher' => '1', 'publisher_action' => $action));
    echo myvesta_get_element('buttons_confirm', '', 'Yes/No', __('Yes').'/'.__('No'));
    echo myvesta_close_form(); exit;
}
if (isset($_POST['No'])) { myvesta_hide_floating_div(); exit; }
if ($action === 'rotate') {
    $secret = isset($_POST['publisher_secret']) && !is_array($_POST['publisher_secret']) ? (string) $_POST['publisher_secret'] : '';
    echo vx_harbor_publisher_rotate_from_panel($myvesta_logged_user, $secret) ? __('Publisher credential rotated.') : __('Publisher rotation failed.');
    exit;
}
$command = VESTA_CMD.'v-disable-user-harbor-registry-publisher '.escapeshellarg($myvesta_logged_user);
$output = array(); $status = 0; exec($command, $output, $status);
echo $status === 0 ? __('Publisher disabled.') : __('Publisher disable failed.');
exit;
