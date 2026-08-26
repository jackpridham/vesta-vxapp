<?php

$root = dirname(__DIR__);
$helper = $root.'/web/inc/vx_custom_domains.php';

if (!defined('JS_LATEST_UPDATE')) {
    define('JS_LATEST_UPDATE', 'test');
}
if (!function_exists('__')) {
    function __($message)
    {
        return $message;
    }
}

if (!is_file($helper)) {
    fwrite(STDERR, "FAIL: missing custom-domain form helper\n");
    exit(1);
}
require_once $helper;

function fail_custom_domains_test($message)
{
    fwrite(STDERR, "FAIL: ".$message."\n");
    exit(1);
}

function assert_custom_domains_same($expected, $actual, $message)
{
    if ($expected !== $actual) {
        fail_custom_domains_test(
            $message."\n  expected: ".var_export($expected, true)
            ."\n  actual:   ".var_export($actual, true)
        );
    }
}

function assert_custom_domains_valid($value, $primary = '')
{
    $error = null;
    if (!vx_custom_domains_validate($value, $primary, $error)) {
        fail_custom_domains_test(
            'valid custom domains were rejected: '.var_export($value, true)
            .' ('.(string) $error.')'
        );
    }
    if ($error !== null && $error !== '') {
        fail_custom_domains_test('successful validation retained an error');
    }
}

function assert_custom_domains_invalid($value, $primary = '')
{
    $error = null;
    if (vx_custom_domains_validate($value, $primary, $error)) {
        fail_custom_domains_test(
            'invalid custom domains were accepted: '.var_export($value, true)
        );
    }
    if (!is_string($error) || trim($error) === '') {
        fail_custom_domains_test('invalid custom domains did not explain the error');
    }
}

function render_custom_domains_for_test($value, $primary = '')
{
    ob_start();
    $returned = vx_custom_domains_render($value, $primary);
    $printed = ob_get_clean();
    return $printed.(is_string($returned) ? $returned : '');
}

foreach (array(
    'vx_custom_domains_values',
    'vx_custom_domains_normalize',
    'vx_custom_domains_validate',
    'vx_custom_domains_render',
) as $required_function) {
    if (!function_exists($required_function)) {
        fail_custom_domains_test('missing helper '.$required_function);
    }
}

assert_custom_domains_same(
    array('example.com', 'www.example.com', 'api.example.com'),
    vx_custom_domains_values(
        "  Example.COM.\r\nwww.example.com,\tAPI.EXAMPLE.COM...  "
    ),
    'legacy separators and harmless domain casing were not normalized'
);
assert_custom_domains_same(
    "example.com\nwww.example.com\napi.example.com",
    vx_custom_domains_normalize(
        "  Example.COM.\r\nwww.example.com,\tAPI.EXAMPLE.COM...  "
    ),
    'custom domains did not serialize to the scalar newline schema'
);
assert_custom_domains_same(
    array('example.com', 'example.com'),
    vx_custom_domains_values("Example.com\nexample.com."),
    'parsing silently removed a duplicate before validation'
);
assert_custom_domains_same(
    '',
    vx_custom_domains_normalize(" \r\n\t "),
    'blank custom domains did not normalize to an empty scalar'
);

assert_custom_domains_valid('');
assert_custom_domains_valid("castlesoncommand.com.au\nwww.castlesoncommand.com.au");
assert_custom_domains_valid('xn--bcher-kva.example');
assert_custom_domains_valid("UPPER.EXAMPLE.\r\napi.upper.example...");

foreach (array(
    'localhost',
    'https://example.com',
    'example.com/path',
    'example.com:443',
    '192.0.2.10',
    '*.example.com',
    '_service.example.com',
    '.example.com',
    'example..com',
    '-edge.example.com',
    'edge-.example.com',
    'café.example',
    str_repeat('a', 64).'.example.com',
    str_repeat('a', 250).'.com',
) as $invalid_domain) {
    assert_custom_domains_invalid($invalid_domain);
}
assert_custom_domains_invalid(array('example.com'));
assert_custom_domains_invalid("example.com\nEXAMPLE.COM.");
assert_custom_domains_invalid('primary.example.com', 'PRIMARY.EXAMPLE.COM.');
$too_many_domains = array();
for ($index = 0; $index < 200; $index++) {
    $too_many_domains[] = 'site-'.$index.'.example.com';
}
assert_custom_domains_invalid(implode("\n", $too_many_domains));

$rendered = render_custom_domains_for_test(
    "Example.COM.\nwww.example.com",
    's-0123456789.managed.example'
);
if (!is_string($rendered) || $rendered === '') {
    fail_custom_domains_test('component renderer returned no markup');
}
if (strpos($rendered, 'name="v_aliases[]"') !== false) {
    fail_custom_domains_test('component changed v_aliases into an array field');
}

$document = new DOMDocument();
$previous_errors = libxml_use_internal_errors(true);
$loaded = $document->loadHTML(
    '<!doctype html><html><body>'.$rendered.'</body></html>',
    LIBXML_HTML_NOIMPLIED | LIBXML_HTML_NODEFDTD
);
libxml_clear_errors();
libxml_use_internal_errors($previous_errors);
if (!$loaded) {
    fail_custom_domains_test('component renderer emitted invalid HTML');
}
$xpath = new DOMXPath($document);
$canonical_fields = $xpath->query('//textarea[@name="v_aliases"]');
assert_custom_domains_same(
    1,
    $canonical_fields->length,
    'component must submit exactly one scalar v_aliases textarea'
);
$canonical_field = $canonical_fields->item(0);
if (!$canonical_field->hasAttribute('hidden')
    && $canonical_field->getAttribute('aria-hidden') !== 'true'
    && strpos($canonical_field->getAttribute('class'), '__serialized') === false) {
    fail_custom_domains_test('canonical v_aliases textarea is visible');
}
assert_custom_domains_same(
    "example.com\nwww.example.com",
    $canonical_field->textContent,
    'hydrated canonical field changed the newline storage schema'
);

$visible_inputs = $xpath->query('//input[@type="text"]');
assert_custom_domains_same(
    2,
    $visible_inputs->length,
    'existing aliases were not hydrated into individual inputs'
);
assert_custom_domains_same(
    'example.com',
    $visible_inputs->item(0)->getAttribute('value'),
    'first hydrated alias changed'
);
assert_custom_domains_same(
    'www.example.com',
    $visible_inputs->item(1)->getAttribute('value'),
    'second hydrated alias changed'
);
foreach ($visible_inputs as $input) {
    if ($input->hasAttribute('name')) {
        fail_custom_domains_test(
            'visible component inputs bypass the scalar v_aliases schema'
        );
    }
}

$buttons = $xpath->query('//button');
if ($buttons->length < 3) {
    fail_custom_domains_test('component lacks add/remove controls');
}
foreach ($buttons as $button) {
    if ($button->getAttribute('type') !== 'button') {
        fail_custom_domains_test('component control can submit the parent form');
    }
    if (trim($button->getAttribute('aria-label')) === '') {
        fail_custom_domains_test('component control lacks an accessible label');
    }
}

$empty_rendered = render_custom_domains_for_test('');
$empty_document = new DOMDocument();
$previous_errors = libxml_use_internal_errors(true);
$empty_document->loadHTML(
    '<!doctype html><html><body>'.$empty_rendered.'</body></html>',
    LIBXML_HTML_NOIMPLIED | LIBXML_HTML_NODEFDTD
);
libxml_clear_errors();
libxml_use_internal_errors($previous_errors);
$empty_xpath = new DOMXPath($empty_document);
assert_custom_domains_same(
    1,
    $empty_xpath->query('//input[@type="text"]')->length,
    'empty state must render one usable custom-domain input'
);

$unsafe_rendered = render_custom_domains_for_test('bad"><script>alert(1)</script>');
if (strpos($unsafe_rendered, '<script>') !== false
    || strpos($unsafe_rendered, 'value="bad"><') !== false) {
    fail_custom_domains_test('custom-domain hydration is not HTML escaped');
}

echo "Custom-domain form tests passed.\n";
