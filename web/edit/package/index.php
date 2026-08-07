<?php
error_reporting(NULL);
ob_start();
$TAB = 'PACKAGE';

// Main include
include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose_package.php");


// Check user
if ($_SESSION['user'] != 'admin') {
    header("Location: /list/user");
    exit;
}

// Check package argument
if (empty($_GET['package'])) {
    header("Location: /list/package/");
    exit;
}


// List package
$v_package = escapeshellarg($_GET['package']);
exec (VESTA_CMD."v-list-user-package ".$v_package." json", $output, $return_var);
$data = json_decode(implode('', $output), true);
unset($output);

// Parse package
$v_package = $_GET['package'];
$v_web_template = $data[$v_package]['WEB_TEMPLATE'];
$v_backend_template = $data[$v_package]['BACKEND_TEMPLATE'];
$v_proxy_template = $data[$v_package]['PROXY_TEMPLATE'];
$v_dns_template = $data[$v_package]['DNS_TEMPLATE'];
$v_web_domains = $data[$v_package]['WEB_DOMAINS'];
$v_web_aliases = $data[$v_package]['WEB_ALIASES'];
$v_dns_domains = $data[$v_package]['DNS_DOMAINS'];
$v_dns_records = $data[$v_package]['DNS_RECORDS'];
$v_mail_domains = $data[$v_package]['MAIL_DOMAINS'];
$v_mail_accounts = $data[$v_package]['MAIL_ACCOUNTS'];
$v_databases = $data[$v_package]['DATABASES'];
$v_cron_jobs = $data[$v_package]['CRON_JOBS'];
$v_docker_containers = $data[$v_package]['DOCKER_CONTAINERS'];
$v_disk_quota = $data[$v_package]['DISK_QUOTA'];
$v_bandwidth = $data[$v_package]['BANDWIDTH'];
$v_shell = $data[$v_package]['SHELL'];
$v_ns = $data[$v_package]['NS'];
$nameservers = explode(",", $v_ns);
$v_ns1 = $nameservers[0];
$v_ns2 = $nameservers[1];
$v_ns3 = $nameservers[2];
$v_ns4 = $nameservers[3];
$v_ns5 = $nameservers[4];
$v_ns6 = $nameservers[5];
$v_ns7 = $nameservers[6];
$v_ns8 = $nameservers[7];
$v_backups = $data[$v_package]['BACKUPS'];
if ($v_docker_containers === NULL || $v_docker_containers === '') $v_docker_containers = "'0'";
$v_date = $data[$v_package]['DATE'];
$v_time = $data[$v_package]['TIME'];
$v_status =  'active';

$compose_package_values = array();
foreach (vx_compose_package_fields() as $field) {
    $form_field = 'v_'.strtolower($field);
    $current_value = isset($data[$v_package][$field])
        ? $data[$v_package][$field] : '0';
    if (is_scalar($current_value)) {
        $current_value = trim((string) $current_value, "'");
    } else {
        $current_value = '0';
    }
    $value = isset($_POST[$form_field])
        ? $_POST[$form_field] : $current_value;
    $compose_package_values[$field] = $value;
    ${$form_field} = is_scalar($value) ? trim((string) $value, "'") : '0';
}

// List web templates
exec (VESTA_CMD."v-list-web-templates json", $output, $return_var);
$web_templates = json_decode(implode('', $output), true);
unset($output);

// List backend templates
if (!empty($_SESSION['WEB_BACKEND'])) {
    exec (VESTA_CMD."v-list-web-templates-backend json", $output, $return_var);
    $backend_templates = json_decode(implode('', $output), true);
    unset($output);
}

// List proxy templates
if (!empty($_SESSION['PROXY_SYSTEM'])) {
    exec (VESTA_CMD."v-list-web-templates-proxy json", $output, $return_var);
    $proxy_templates = json_decode(implode('', $output), true);
    unset($output);
}


// List dns templates
exec (VESTA_CMD."v-list-dns-templates json", $output, $return_var);
$dns_templates = json_decode(implode('', $output), true);
unset($output);

// List shels
exec (VESTA_CMD."v-list-sys-shells json", $output, $return_var);
$shells = json_decode(implode('', $output), true);
unset($output);

// Check POST request
if (!empty($_POST['save'])) {

    // Check token
    if ((!isset($_POST['token'])) || ($_SESSION['token'] != $_POST['token'])) {
        header('location: /login/');
        exit();
    }

    $compose_package_normalized =
        vx_compose_package_normalize($compose_package_values);

    // Check empty fields
    if (empty($_POST['v_package'])) $errors[] = __('package');
    if (empty($_POST['v_web_template'])) $errors[] = __('web template');
    if (!empty($_SESSION['WEB_BACKEND'])) {
        if (empty($_POST['v_backend_template'])) $errors[] = __('backend template');
    }
    if (!empty($_SESSION['PROXY_SYSTEM'])) {
        if (empty($_POST['v_proxy_template'])) $errors[] = __('proxy template');
    }
    if (empty($_POST['v_dns_template'])) $errors[] = __('dns template');
    if (empty($_POST['v_shell'])) $errrors[] = __('shell');
    if (!isset($_POST['v_web_domains'])) $errors[] = __('web domains');
    if (!isset($_POST['v_web_aliases'])) $errors[] = __('web aliases');
    if (!isset($_POST['v_dns_domains'])) $errors[] = __('dns domains');
    if (!isset($_POST['v_dns_records'])) $errors[] = __('dns records');
    if (!isset($_POST['v_mail_domains'])) $errors[] = __('mail domains');
    if (!isset($_POST['v_mail_accounts'])) $errors[] = __('mail accounts');
    if (!isset($_POST['v_databases'])) $errors[] = __('databases');
    if (!isset($_POST['v_cron_jobs'])) $errors[] = __('cron jobs');
    if (!isset($_POST['v_docker_containers'])) $errors[] = __('Docker');
    if (!isset($_POST['v_backups'])) $errors[] = __('backups');
    if (!isset($_POST['v_disk_quota'])) $errors[] = __('quota');
    if (!isset($_POST['v_bandwidth'])) $errors[] = __('bandwidth');
    if (empty($_POST['v_ns1'])) $errors[] = __('ns1');
    if (empty($_POST['v_ns2'])) $errors[] = __('ns2');
    if ($compose_package_normalized === false) {
        $_SESSION['error_msg'] = __('Invalid Compose quota value.');
    }
    if (!empty($errors[0])) {
        foreach ($errors as $i => $error) {
            if ( $i == 0 ) {
                $error_msg = $error;
            } else {
                $error_msg = $error_msg.", ".$error;
            }
        }
        $_SESSION['error_msg'] = __('Field "%s" can not be blank.',$error_msg);
    }

    // Protect input
    $v_package = escapeshellarg($_POST['v_package']);
    $v_web_template = escapeshellarg($_POST['v_web_template']);
    if (!empty($_SESSION['WEB_BACKEND'])) {
        $v_backend_template = escapeshellarg($_POST['v_backend_template']);
    }
    if (!empty($_SESSION['PROXY_SYSTEM'])) {
        $v_proxy_template = escapeshellarg($_POST['v_proxy_template']);
    }
    $v_dns_template = escapeshellarg($_POST['v_dns_template']);
    $v_shell = escapeshellarg($_POST['v_shell']);
    $v_web_domains = escapeshellarg($_POST['v_web_domains']);
    $v_web_aliases = escapeshellarg($_POST['v_web_aliases']);
    $v_dns_domains = escapeshellarg($_POST['v_dns_domains']);
    $v_dns_records = escapeshellarg($_POST['v_dns_records']);
    $v_mail_domains = escapeshellarg($_POST['v_mail_domains']);
    $v_mail_accounts = escapeshellarg($_POST['v_mail_accounts']);
    $v_databases = escapeshellarg($_POST['v_databases']);
    $v_cron_jobs = escapeshellarg($_POST['v_cron_jobs']);
    $v_docker_containers = escapeshellarg($_POST['v_docker_containers']);
    $v_backups = escapeshellarg($_POST['v_backups']);
    $v_disk_quota = escapeshellarg($_POST['v_disk_quota']);
    $v_bandwidth = escapeshellarg($_POST['v_bandwidth']);
    $v_ns1 = trim($_POST['v_ns1'], '.');
    $v_ns2 = trim($_POST['v_ns2'], '.');
    $v_ns3 = trim($_POST['v_ns3'], '.');
    $v_ns4 = trim($_POST['v_ns4'], '.');
    $v_ns5 = trim($_POST['v_ns5'], '.');
    $v_ns6 = trim($_POST['v_ns6'], '.');
    $v_ns7 = trim($_POST['v_ns7'], '.');
    $v_ns8 = trim($_POST['v_ns8'], '.');
    $v_ns = $v_ns1.",".$v_ns2;
    if (!empty($v_ns3)) $v_ns .= ",".$v_ns3;
    if (!empty($v_ns4)) $v_ns .= ",".$v_ns4;
    if (!empty($v_ns5)) $v_ns .= ",".$v_ns5;
    if (!empty($v_ns6)) $v_ns .= ",".$v_ns6;
    if (!empty($v_ns7)) $v_ns .= ",".$v_ns7;
    if (!empty($v_ns8)) $v_ns .= ",".$v_ns8;
    $v_ns = escapeshellarg($v_ns);
    $v_time = escapeshellarg(date('H:i:s'));
    $v_date = escapeshellarg(date('Y-m-d'));

    if (empty($_SESSION['error_msg'])) {
        $compose_package_lines =
            vx_compose_package_lines($compose_package_normalized);
        if ($compose_package_lines === false) {
            $_SESSION['error_msg'] = __('Invalid Compose quota value.');
        }
    }

    if (empty($_SESSION['error_msg'])) {
        // Create temprorary directory
        exec ('mktemp -d', $output, $return_var);
        $tmpdir = $output[0];
        unset($output);

        // Save package file on a fs
        $pkg = "WEB_TEMPLATE=".$v_web_template."\n";
        $pkg .= "BACKEND_TEMPLATE=".$v_backend_template."\n";
        $pkg .= "PROXY_TEMPLATE=".$v_proxy_template."\n";
        $pkg .= "DNS_TEMPLATE=".$v_dns_template."\n";
        $pkg .= "WEB_DOMAINS=".$v_web_domains."\n";
        $pkg .= "WEB_ALIASES=".$v_web_aliases."\n";
        $pkg .= "DNS_DOMAINS=".$v_dns_domains."\n";
        $pkg .= "DNS_RECORDS=".$v_dns_records."\n";
        $pkg .= "MAIL_DOMAINS=".$v_mail_domains."\n";
        $pkg .= "MAIL_ACCOUNTS=".$v_mail_accounts."\n";
        $pkg .= "DATABASES=".$v_databases."\n";
        $pkg .= "CRON_JOBS=".$v_cron_jobs."\n";
        $pkg .= "DOCKER_CONTAINERS=".$v_docker_containers."\n";
        $pkg .= $compose_package_lines;
        $pkg .= "DISK_QUOTA=".$v_disk_quota."\n";
        $pkg .= "BANDWIDTH=".$v_bandwidth."\n";
        $pkg .= "NS=".$v_ns."\n";
        $pkg .= "SHELL=".$v_shell."\n";
        $pkg .= "BACKUPS=".$v_backups."\n";
        $pkg .= "TIME=".$v_time."\n";
        $pkg .= "DATE=".$v_date."\n";
        $fp = fopen($tmpdir."/".$_POST['v_package'].".pkg", 'w');
        fwrite($fp, $pkg);
        fclose($fp);

        // Save changes
        exec (VESTA_CMD."v-add-user-package ".$tmpdir." ".$v_package." yes", $output, $return_var);
        check_return_code($return_var,$output);
        unset($output);

        // Remove temporary dir
        exec ('rm -rf '.escapeshellarg($tmpdir), $output, $return_var);
        unset($output);

        // Propogate new package
        exec (VESTA_CMD."v-update-user-package ".$v_package." json", $output, $return_var);
        check_return_code($return_var,$output);
        unset($output);

        // Set success message
        if (empty($_SESSION['error_msg'])) {
            $_SESSION['ok_msg'] = __('Changes has been saved.');
        }
    }
}


// Render page
render_page($user, $TAB, 'edit_package');

// Flush session messages
unset($_SESSION['error_msg']);
unset($_SESSION['ok_msg']);
