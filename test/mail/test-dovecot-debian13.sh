#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
template="$repo_root/install/debian/13/dovecot"

expected_header=$'dovecot_config_version = 2.4.0\ndovecot_storage_version = 2.4.0'
actual_header=$(sed -n '1p;2p' "$template/dovecot.conf")
[[ "$actual_header" == "$expected_header" ]]

grep -Fqx 'auth_allow_cleartext = yes' "$template/conf.d/10-auth.conf"
grep -Fqx 'mail_driver = maildir' "$template/conf.d/10-mail.conf"
grep -Fqx 'mail_path = ~/mail/%{user | domain}/%{user | username}' "$template/conf.d/10-mail.conf"
grep -Fqx 'pop3_uidl_format = %{uid | hex(8)}%{uidvalidity | hex(8)}' "$template/conf.d/10-mail.conf"
grep -Fqx 'ssl_server_cert_file = /usr/local/vesta/ssl/certificate.crt' "$template/conf.d/10-ssl.conf"
grep -Fqx 'ssl_server_key_file = /usr/local/vesta/ssl/certificate.key' "$template/conf.d/10-ssl.conf"
grep -Fqx 'passdb passwd-file {' "$template/conf.d/auth-passwdfile.conf.ext"
grep -Fqx 'userdb passwd-file {' "$template/conf.d/auth-passwdfile.conf.ext"

! grep -R -Eq '^[[:space:]]*(disable_plaintext_auth|mail_location|ssl_cert|ssl_key)[[:space:]]*=' "$template"
grep -Fq "[ \"\$release\" -eq 13 ]" "$repo_root/install/vst-install-debian.sh"
grep -Fq -- "-name '*.conf.ext'" "$repo_root/install/vst-install-debian.sh"

printf 'Debian 13 Dovecot template checks passed.\n'
