<?php

$mode = isset($argv[1]) ? $argv[1] : '';
$actor = isset($argv[2]) ? $argv[2] : '';
$owner = isset($argv[3]) ? $argv[3] : '';
if (!in_array($mode, array('index', 'router'), true)
    || !preg_match('/^[a-z0-9-]+$/D', $actor)
    || !preg_match('/^[a-z0-9-]+$/D', $owner)) {
    exit(2);
}

$document_root = sys_get_temp_dir().'/vx-ingress-modal-'
    .bin2hex(random_bytes(8));
mkdir($document_root.'/ajax/docker/actions', 0700, true);
mkdir($document_root.'/inc', 0700, true);
$repo_root = dirname(__DIR__);

file_put_contents(
    $document_root.'/ajax/include_authentication_check.php',
    "<?php\n\$myvesta_logged_user = ".var_export($actor, true).";\n"
);
file_put_contents(
    $document_root.'/inc/form-elements.php',
    <<<'PHP'
<?php
function myvesta_open_form($action) { return '<form action="'.$action.'">'; }
function myvesta_close_form() { return '</form>'; }
function myvesta_get_hidden_fields() { return '<input name="dataset">'; }
function myvesta_get_element($type, $id, $name, $label) {
    return '<button name="'.$name.'">'.$label.'</button>';
}
function myvesta_get_disabled_textarea($value) {
    return '<textarea disabled>'.$value.'</textarea>';
}
PHP
);
file_put_contents($document_root.'/inc/vx_docker.php', "<?php\n");
file_put_contents(
    $document_root.'/inc/vx_compose.php',
    <<<'PHP'
<?php
function __($message) { return $message; }
function vx_compose_resolve_accessible_project($owner, $project, $actor) {
    return ($actor === 'admin' || $actor === $owner)
        && $project === 'app' ? array('OWNER' => $owner, 'PROJECT' => $project)
        : array();
}
function vx_compose_actor_can_mutate_project() { return false; }
function vx_compose_actor_has_capability() { return false; }
function vx_compose_pretty_json($value) { return json_encode($value); }
function vx_compose_ingress_consumers_payload($owner, $project, $actor) {
    $GLOBALS['ingress_call'] = array($owner, $project, $actor);
    if ($actor === 'admin') {
        return array(array(
            'OWNER' => 'consumer',
            'DOMAIN' => 'app.example.test',
            'HEADER_NAMES' => array('X-Protected-Name'),
        ));
    }
    return array('COUNT' => 1);
}
PHP
);
file_put_contents(
    $document_root.'/ajax/docker/actions/ingress_consumers.php',
    "<?php require ".var_export(
        $repo_root.'/web/ajax/docker/actions/ingress_consumers.php',
        true
    ).";\n"
);

$_SERVER['DOCUMENT_ROOT'] = $document_root;
$_POST = array(
    'dataset' => array(
        'container_name' => 'app',
        'owner' => $owner,
    ),
);
if ($mode === 'router') {
    $_POST['docker_ingress_consumers'] = '1';
}

register_shutdown_function(function () use ($document_root) {
    echo "\n__INGRESS_STATE__".json_encode(array(
        'call' => isset($GLOBALS['ingress_call'])
            ? $GLOBALS['ingress_call'] : null,
    ))."\n";
    @unlink($document_root.'/ajax/docker/actions/ingress_consumers.php');
    @unlink($document_root.'/ajax/include_authentication_check.php');
    @unlink($document_root.'/inc/form-elements.php');
    @unlink($document_root.'/inc/vx_docker.php');
    @unlink($document_root.'/inc/vx_compose.php');
    @rmdir($document_root.'/ajax/docker/actions');
    @rmdir($document_root.'/ajax/docker');
    @rmdir($document_root.'/ajax');
    @rmdir($document_root.'/inc');
    @rmdir($document_root);
});

$target = $repo_root.'/web/ajax/docker/'
    .($mode === 'index' ? 'index.php' : 'router.php');
require $target;
