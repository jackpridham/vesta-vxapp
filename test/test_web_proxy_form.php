<?php

$root = dirname(__DIR__);
require_once $root.'/web/inc/vx_proxy_form.php';

$failures = array();

function fail_test($message)
{
    global $failures;
    $failures[] = $message;
}

function assert_same($expected, $actual, $message)
{
    if ($expected !== $actual) {
        fail_test($message."\n  expected: ".var_export($expected, true)."\n  actual:   ".var_export($actual, true));
    }
}

function assert_source_contains($source, $needle, $message)
{
    if (strpos($source, $needle) === false) {
        fail_test($message);
    }
}

function headers_from($value)
{
    $_POST = array('v_proxy_headers' => $value);
    return vx_proxy_headers_from_post();
}

assert_same('', headers_from(''), 'empty headers should remain empty');
assert_same('X-One: one', headers_from('X-One: one'), 'one header should remain one header');
assert_same(
    'X-One: one||X-Two: two',
    headers_from("X-One: one\nX-Two: two"),
    'multiline headers should use the persisted separator'
);
assert_same(
    'X-One: one||X-Two: two',
    headers_from("X-One: one\r\nX-Two: two\r\n"),
    'CRLF headers should normalize without empty entries'
);
assert_same(
    'X-One: one||X-Two: two',
    headers_from("\nX-One: one\n\n \t \nX-Two: two\n"),
    'blank header lines should be removed'
);
assert_same(
    'X-One: one||X-Two: two',
    headers_from("  X-One: one  \n\tX-Two: two \t"),
    'surrounding header whitespace should be trimmed'
);
assert_same(
    "Header: Value\nHeader-Two: Value",
    vx_proxy_headers_to_text('Header: Value||Header-Two: Value'),
    'persisted headers should be restored one per textarea line'
);

$_POST = array(
    'v_proxy_target' => 'http://127.0.0.1:8420/app',
    'v_proxy_mode' => 'proxy',
    'v_proxy_profile' => 'application',
    'v_proxy_preserve_host' => 'yes',
    'v_proxy_timeout' => '75',
    'v_proxy_headers' => "X-Business-GUID: EXAMPLE-GUID\nX-Another: second",
);
$expectedLongFlags =
    " --proxy-target ".escapeshellarg('http://127.0.0.1:8420/app').
    " --proxy-mode ".escapeshellarg('proxy').
    " --proxy-profile ".escapeshellarg('application').
    " --proxy-preserve-host ".escapeshellarg('yes').
    " --proxy-timeout ".escapeshellarg('75').
    " --header ".escapeshellarg('X-Business-GUID: EXAMPLE-GUID').
    " --header ".escapeshellarg('X-Another: second');
assert_same($expectedLongFlags, vx_proxy_long_flags_from_post(), 'add helper emitted the wrong named CLI fields');

$expectedChangeArgs =
    escapeshellarg('proxy')." ".
    escapeshellarg('http://127.0.0.1:8420/app')." ".
    escapeshellarg('application')." ".
    escapeshellarg('yes')." ".
    escapeshellarg('75')." ".
    escapeshellarg('X-Business-GUID: EXAMPLE-GUID||X-Another: second');
assert_same($expectedChangeArgs, vx_proxy_change_args_from_post(), 'edit helper emitted the wrong positional CLI fields');

$_POST = array('v_proxy_target' => '');
assert_same('', vx_proxy_long_flags_from_post(), 'empty add target should not emit native proxy flags');

$addController = file_get_contents($root.'/web/add/web/index.php');
$editController = file_get_contents($root.'/web/edit/web/index.php');
assert_source_contains($addController, 'v-add-web-domain ".$user.', 'create controller is not owner-scoped through $user');
assert_source_contains($addController, '$proxy_options = vx_proxy_long_flags_from_post();', 'create controller does not use the native proxy helper');
assert_source_contains($addController, "VESTA_CMD.\"v-add-web-domain ", 'create controller does not call v-add-web-domain');
assert_source_contains($editController, '$v_username = $user;', 'edit controller does not bind mutations to the resolved owner');
assert_source_contains($editController, '$proxy_args = vx_proxy_change_args_from_post();', 'edit controller does not use the positional proxy helper');
assert_source_contains($editController, 'v-change-web-domain-proxy-options ', 'edit controller does not call v-change-web-domain-proxy-options');
assert_source_contains($editController, 'v-delete-web-domain-proxy ', 'disable controller does not call v-delete-web-domain-proxy');

foreach (array($addController, $editController) as $controller) {
    assert_source_contains($controller, "(!isset(\$_POST['token']))", 'controller CSRF token presence check changed');
    assert_source_contains($controller, "(\$_SESSION['token'] != \$_POST['token'])", 'controller CSRF token comparison changed');
}

$templates = array(
    $root.'/web/templates/admin/add_web.html',
    $root.'/web/templates/admin/edit_web.html',
    $root.'/web/templates/user/edit_web.html',
);
foreach ($templates as $template) {
    $source = file_get_contents($template);
    assert_source_contains($source, 'name="token" value="<?=$_SESSION[\'token\']?>"', basename($template).' lost its CSRF token field');
    assert_source_contains($source, 'name="v_proxy_target"', basename($template).' does not expose the proxy target');
    assert_source_contains($source, 'name="v_proxy_headers"', basename($template).' does not expose proxy headers');
}

if (!empty($failures)) {
    foreach ($failures as $failure) {
        fwrite(STDERR, "FAIL: ".$failure."\n");
    }
    exit(1);
}

echo "Web proxy form tests passed.\n";
