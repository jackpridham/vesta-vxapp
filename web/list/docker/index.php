<?php
error_reporting(NULL);
$TAB = 'SERVER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");

if ($_SESSION['user'] != 'admin') {
    header('Location: /list/user');
    exit;
}

exec(VESTA_CMD."v-check-docker-engine json", $output, $return_var);
$docker_state = json_decode(implode('', $output), true);
if (!is_array($docker_state)) {
    $docker_state = array();
}
unset($output);

$docker_available = (!empty($docker_state['DOCKER_AVAILABLE']) && $docker_state['DOCKER_AVAILABLE'] === 'yes');
$data = array();

if ($docker_available) {
    exec(VESTA_CMD."v-list-docker-containers json", $output, $return_var);
    $data = json_decode(implode('', $output), true);
    if (!is_array($data)) {
        $data = array();
    }
    unset($output);
}

render_page($user, $TAB, 'list_docker');

$_SESSION['back'] = $_SERVER['REQUEST_URI'];
