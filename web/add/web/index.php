<?php
error_reporting(NULL);
ob_start();
$TAB = 'WEB';

// Main include
include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_proxy_form.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_custom_domains.php");

// Check POST request
if (!empty($_POST['ok'])) {

    // Check token
    if ((!isset($_POST['token'])) || ($_SESSION['token'] != $_POST['token'])) {
        header('location: /login/');
        exit();
    }

    // Validate and canonicalize the scalar aliases field before any Vesta
    // mutation. The reusable form component serializes its rows with LF.
    $posted_aliases = isset($_POST['v_aliases']) ? $_POST['v_aliases'] : '';
    $custom_domain_error = '';
    if (!vx_custom_domains_validate($posted_aliases, '', $custom_domain_error)) {
        $_SESSION['error_msg'] = __($custom_domain_error);
    }
    $v_aliases = vx_custom_domains_normalize($posted_aliases);
    $_POST['v_aliases'] = $v_aliases;

    // Managed websites always receive Vesta-owned Origin CA SSL during the
    // allocator transaction. Ignore legacy/manual certificate fields even if
    // a caller crafts them into the POST body.
    $_POST['v_ssl'] = '';
    $_POST['v_letsencrypt'] = '';
    $_POST['v_ssl_crt'] = '';
    $_POST['v_ssl_key'] = '';
    $_POST['v_ssl_ca'] = '';
    $_POST['v_ssl_home'] = 'same';

    // Check for empty fields
    if (empty($_POST['v_ip'])) $errors[] = __('ip');
    if ((!empty($_POST['v_ssl'])) && (empty($_POST['v_ssl_crt']))&& (empty($_POST['v_letsencrypt']))) $errors[] = __('ssl certificate');
    if ((!empty($_POST['v_ssl'])) && (empty($_POST['v_ssl_key']))&& (empty($_POST['v_letsencrypt']))) $errors[] = __('ssl key');
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

    // Check stats password length
    if ((!empty($_POST['v_stats'])) && (empty($_SESSION['error_msg']))) {
        if (!empty($_POST['v_stats_user'])) {
            $pw_len = strlen($_POST['v_stats_password']);
            if ($pw_len < 6 ) $_SESSION['error_msg'] = __('Password is too short.',$error_msg);
        }
    }

    // Define domain ip address
    $v_ip = escapeshellarg($_POST['v_ip']);

    // Define domain aliases
    $aliases_arr = vx_custom_domains_values($v_aliases);
    $aliases = empty($aliases_arr) ? 'none' : escapeshellarg(implode(',', $aliases_arr));

    // Define proxy extensions
    $v_proxy_ext = $_POST['v_proxy_ext'];
    $proxy_ext = preg_replace("/\n/", ",", $v_proxy_ext);
    $proxy_ext = preg_replace("/\r/", ",", $proxy_ext);
    $proxy_ext = preg_replace("/\t/", ",", $proxy_ext);
    $proxy_ext = preg_replace("/ /", ",", $proxy_ext);
    $proxy_ext_arr = explode(",", $proxy_ext);
    $proxy_ext_arr = array_unique($proxy_ext_arr);
    $proxy_ext_arr = array_filter($proxy_ext_arr);
    $proxy_ext = implode(",",$proxy_ext_arr);
    $proxy_ext = escapeshellarg($proxy_ext);
    $proxy_options = vx_proxy_long_flags_from_post();
    if ($proxy_options !== '') {
        $_POST['v_proxy'] = 'on';
    }

    // Define other options
    $v_elog = $_POST['v_elog'];
    $v_ssl = $_POST['v_ssl'];
    $v_ssl_crt = $_POST['v_ssl_crt'];
    $v_ssl_key = $_POST['v_ssl_key'];
    $v_ssl_ca = $_POST['v_ssl_ca'];
    $v_ssl_home = $_POST['v_ssl_home'];
    $v_letsencrypt = $_POST['v_letsencrypt'];
    $v_stats = escapeshellarg($_POST['v_stats']);
    $v_stats_user = $_POST['v_stats_user'];
    $v_stats_password = $_POST['v_stats_password'];
    $v_ftp = $_POST['v_ftp'];
    $v_ftp_user = $_POST['v_ftp_user'];
    $v_ftp_password = $_POST['v_ftp_password'];
    $v_ftp_email = $_POST['v_ftp_email'];
    // Set advanced option checkmark
    if (!empty($_POST['v_proxy'])) $v_adv = 'yes';
    if ($proxy_options !== '') $v_adv = 'yes';
    if (!empty($_POST['v_ftp'])) $v_adv = 'yes';
    if ($_POST['v_proxy_ext'] != $v_proxy_ext) $v_adv = 'yes';
    if ((!empty($_POST['v_ssl'])) || (!empty($_POST['v_elog']))) $v_adv = 'yes';
    if ((!empty($_POST['v_ssl_crt'])) || (!empty($_POST['v_ssl_key']))) $v_adv = 'yes';
    if ((!empty($_POST['v_ssl_ca'])) || ($_POST['v_stats'] != 'none')) $v_adv = 'yes';
    if ((!empty($_POST['v_letsencrypt']))) $v_adv = 'yes';

    // Check advanced features
    if (empty($_POST['v_proxy'])) $v_proxy = 'off';

    // Add a web domain with a Vesta-generated managed hostname.
    $generated_domain = '';
    $domain_added = false;
    if (empty($_SESSION['error_msg'])) {
        exec (VESTA_CMD."v-add-vx-managed-web-domain ".escapeshellarg($user)." ".$v_ip." no ".$aliases." ".$proxy_ext.$proxy_options, $output, $return_var);
        check_return_code($return_var,$output);
        if (empty($_SESSION['error_msg'])) {
            $generated_domain = trim(implode("\n", $output));
            if (!preg_match('/^s-[a-f0-9]{10}\.(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))*$/D', $generated_domain)) {
                $_SESSION['error_msg'] = __('Managed web domain allocator returned an invalid hostname.');
            }
        }
        unset($output);
        if (empty($_SESSION['error_msg'])) {
            $v_domain = escapeshellarg($generated_domain);
            $v_ftp_user_prepath = $panel[$user]['HOME']."/web/".$generated_domain;
            $domain_added = true;
        }
    }

    // Delete proxy support
    if ((!empty($_SESSION['PROXY_SYSTEM'])) && ($_POST['v_proxy'] == 'off')  && (empty($_SESSION['error_msg']))) {
        $ext = escapeshellarg($ext);
        exec (VESTA_CMD."v-delete-web-domain-proxy ".$user." ".$v_domain." no", $output, $return_var);
        check_return_code($return_var,$output);
        unset($output);
    }

    // Add Lets Encrypt support
     if ((!empty($_POST['v_letsencrypt'])) && (empty($_SESSION['error_msg']))) {
        exec (VESTA_CMD."v-schedule-letsencrypt-domain ".$user." ".$v_domain, $output, $return_var);
        check_return_code($return_var,$output);
        unset($output);
     } else {
        // Add SSL certificates only if Lets Encrypt is off
         if ((!empty($_POST['v_ssl'])) && (empty($_SESSION['error_msg']))) {
             exec ('mktemp -d', $output, $return_var);
             $tmpdir = $output[0];
             unset($output);

             // Save certificate
             if (!empty($_POST['v_ssl_crt'])) {
                 $fp = fopen($tmpdir."/".$generated_domain.".crt", 'w');
                 fwrite($fp, str_replace("\r\n", "\n", $_POST['v_ssl_crt']));
                 fwrite($fp, "\n");
                 fclose($fp);
             }

             // Save private key
             if (!empty($_POST['v_ssl_key'])) {
                 $fp = fopen($tmpdir."/".$generated_domain.".key", 'w');
                 fwrite($fp, str_replace("\r\n", "\n", $_POST['v_ssl_key']));
                 fwrite($fp, "\n");
                 fclose($fp);
             }

             // Save CA bundle
             if (!empty($_POST['v_ssl_ca'])) {
                 $fp = fopen($tmpdir."/".$generated_domain.".ca", 'w');
                 fwrite($fp, str_replace("\r\n", "\n", $_POST['v_ssl_ca']));
                 fwrite($fp, "\n");
                 fclose($fp);
             }

             $v_ssl_home = escapeshellarg($_POST['v_ssl_home']);
             exec (VESTA_CMD."v-add-web-domain-ssl ".$user." ".$v_domain." ".$tmpdir." ".$v_ssl_home." no", $output, $return_var);
             check_return_code($return_var,$output);
             unset($output);
         }
     }

    // Add web stats
    if ((!empty($_POST['v_stats'])) && ($_POST['v_stats'] != 'none' ) && (empty($_SESSION['error_msg']))) {
        $v_stats = escapeshellarg($_POST['v_stats']);
        exec (VESTA_CMD."v-add-web-domain-stats ".$user." ".$v_domain." ".$v_stats, $output, $return_var);
        check_return_code($return_var,$output);
        unset($output);
    }

    // Add web stats password
    if ((!empty($_POST['v_stats_user'])) && (empty($_SESSION['error_msg']))) {
        $v_stats_user = escapeshellarg($_POST['v_stats_user']);
        $v_stats_password = tempnam("/tmp","vst");
        $fp = fopen($v_stats_password, "w");
        fwrite($fp, $_POST['v_stats_password']."\n");
        fclose($fp);
        exec (VESTA_CMD."v-add-web-domain-stats-user ".$user." ".$v_domain." ".$v_stats_user." ".$v_stats_password, $output, $return_var);
        check_return_code($return_var,$output);
        unset($output);
        unlink($v_stats_password);
        $v_stats_password = escapeshellarg($_POST['v_stats_password']);
    }

    // Restart web server
    if (empty($_SESSION['error_msg'])) {
        exec (VESTA_CMD."v-restart-web", $output, $return_var);
        check_return_code($return_var,$output);
        unset($output);
    }

    // Restart proxy server
    if ((!empty($_SESSION['PROXY_SYSTEM'])) && ($_POST['v_proxy'] == 'on') && (empty($_SESSION['error_msg']))) {
        exec (VESTA_CMD."v-restart-proxy", $output, $return_var);
        check_return_code($return_var,$output);
        unset($output);
    }

    // Add FTP
    if ((!empty($_POST['v_ftp'])) && (empty($_SESSION['error_msg']))) {
        $v_ftp_users_updated = array();
        foreach ($_POST['v_ftp_user'] as $i => $v_ftp_user_data) {
            if ($v_ftp_user_data['is_new'] == 1) {
                if ((!empty($v_ftp_user_data['v_ftp_email'])) && (!filter_var($v_ftp_user_data['v_ftp_email'], FILTER_VALIDATE_EMAIL))) $_SESSION['error_msg'] = __('Please enter valid email address.');
                if (empty($v_ftp_user_data['v_ftp_user'])) $errors[] = 'ftp user';
                if (empty($v_ftp_user_data['v_ftp_password'])) $errors[] = 'ftp user password';
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

                // Validate email
                if ((!empty($v_ftp_user_data['v_ftp_email'])) && (!filter_var($v_ftp_user_data['v_ftp_email'], FILTER_VALIDATE_EMAIL))) {
                    $_SESSION['error_msg'] = __('Please enter valid email address.');
                }

                // Check ftp password length
                if ((!empty($v_ftp_user_data['v_ftp']))) {
                    if (!empty($v_ftp_user_data['v_ftp_user'])) {
                        $pw_len = strlen($v_ftp_user_data['v_ftp_password']);
                        if ($pw_len < 6 ) $_SESSION['error_msg'] = __('Password is too short.',$error_msg);
                    }
                }

                $v_ftp_user_data['v_ftp_user'] = preg_replace("/^".$user."_/i", "", $v_ftp_user_data['v_ftp_user']);
                $v_ftp_username      = $v_ftp_user_data['v_ftp_user'];
                $v_ftp_username_full = $user . '_' . $v_ftp_user_data['v_ftp_user'];
                $v_ftp_user = escapeshellarg($v_ftp_user_data['v_ftp_user']);
                if ($domain_added) {
                    $v_ftp_path = escapeshellarg(trim($v_ftp_user_data['v_ftp_path']));
                    $v_ftp_password = tempnam("/tmp","vst");
                    $fp = fopen($v_ftp_password, "w");
                    fwrite($fp, $v_ftp_user_data['v_ftp_password']."\n");
                    fclose($fp);
                    exec (VESTA_CMD."v-add-web-domain-ftp ".$user." ".$v_domain." ".$v_ftp_user." ".$v_ftp_password . " " . $v_ftp_path, $output, $return_var);
                    check_return_code($return_var,$output);
                    unset($output);
                    unlink($v_ftp_password);
                    if ((!empty($v_ftp_user_data['v_ftp_email'])) && (empty($_SESSION['error_msg']))) {
                        $to = $v_ftp_user_data['v_ftp_email'];
                        $subject = __("FTP login credentials");
                        $from = __('MAIL_FROM',$generated_domain);
                        $mailtext = __('FTP_ACCOUNT_READY',$generated_domain,$user,$v_ftp_user_data['v_ftp_user'],$v_ftp_user_data['v_ftp_password']);
                        send_email($to, $subject, $mailtext, $from);
                        unset($v_ftp_email);
                    }
                } else {
                    $return_var = -1;
                }

                if ($return_var == 0) {
                    $v_ftp_password = "••••••••";
                    $v_ftp_user_data['is_new'] = 0;
                } else {
                    $v_ftp_user_data['is_new'] = 1;
                }

                $v_ftp_username = preg_replace("/^".$user."_/", "", $v_ftp_user_data['v_ftp_user']);
                $v_ftp_users_updated[] = array(
                    'is_new'            => $v_ftp_user_data['is_new'],
                    'v_ftp_user'        => $return_var == 0 ? $v_ftp_username_full : $v_ftp_username,
                    'v_ftp_password'    => $v_ftp_password,
                    'v_ftp_path'        => $v_ftp_user_data['v_ftp_path'],
                    'v_ftp_email'       => $v_ftp_user_data['v_ftp_email'],
                    'v_ftp_pre_path'    => $v_ftp_user_prepath
                );
                continue;
            }
        }

        if (!empty($_SESSION['error_msg']) && $domain_added) {
            $_SESSION['ok_msg'] = __('WEB_DOMAIN_CREATED_OK',htmlentities($generated_domain),htmlentities($generated_domain));
            $_SESSION['flash_error_msg'] = $_SESSION['error_msg'];
            $url = '/edit/web/?domain='.rawurlencode($generated_domain);
            header('Location: ' . $url);
            exit;
        }
    }

    // Flush field values on success
    if (empty($_SESSION['error_msg'])) {
        $_SESSION['ok_msg'] = __('WEB_DOMAIN_CREATED_OK',htmlentities($generated_domain),htmlentities($generated_domain));
        unset($v_domain);
        unset($v_aliases);
        unset($v_ssl);
        unset($v_ssl_crt);
        unset($v_ssl_key);
        unset($v_ssl_ca);
        unset($v_stats_user);
        unset($v_stats_password);
        unset($v_ftp);
        unset($v_proxy_target);
        unset($v_proxy_headers);
    }
}

// Define user variables
$v_ftp_user_prepath = $panel[$user]['HOME'] . "/web";
$v_ftp_email = $panel[$user]['CONTACT'];
$v_proxy_mode = isset($_POST['v_proxy_mode']) ? $_POST['v_proxy_mode'] : 'proxy';
$v_proxy_target = isset($_POST['v_proxy_target']) ? $_POST['v_proxy_target'] : '';
$v_proxy_profile = isset($_POST['v_proxy_profile']) ? $_POST['v_proxy_profile'] : 'standard';
$v_proxy_preserve_host = isset($_POST['v_proxy_preserve_host']) ? $_POST['v_proxy_preserve_host'] : 'yes';
$v_proxy_timeout = isset($_POST['v_proxy_timeout']) ? $_POST['v_proxy_timeout'] : '60';
$v_proxy_headers = isset($_POST['v_proxy_headers']) ? $_POST['v_proxy_headers'] : '';

// List IP addresses
exec (VESTA_CMD."v-list-user-ips ".$user." json", $output, $return_var);
$ips = json_decode(implode('', $output), true);
unset($output);

// List web stat engines
exec (VESTA_CMD."v-list-web-stats json", $output, $return_var);
$stats = json_decode(implode('', $output), true);
unset($output);

// Render page
render_page($user, $TAB, 'add_web');

// Flush session messages
unset($_SESSION['error_msg']);
unset($_SESSION['ok_msg']);
