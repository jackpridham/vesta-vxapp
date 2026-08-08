# Managed by Vesta. Do not expose any other Harbor route.
location = /v2/ {
    client_max_body_size 0;
    client_body_timeout 60s;
    limit_conn vesta_harbor_registry 20;
    access_log /var/log/vesta/harbor-registry-access.log vesta_harbor_registry buffer=32k flush=5s;
    proxy_set_header Host $host;
    proxy_set_header Cookie "";
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Port __VESTA_TLS_PORT__;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_hide_header Set-Cookie;
    proxy_connect_timeout 10s;
    proxy_read_timeout 900s;
    proxy_send_timeout 900s;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_pass http://unix:/run/vesta-harbor/proxy.sock;
}
location ^~ /v2/ {
    client_max_body_size 0;
    client_body_timeout 60s;
    limit_conn vesta_harbor_registry 20;
    access_log /var/log/vesta/harbor-registry-access.log vesta_harbor_registry buffer=32k flush=5s;
    proxy_set_header Host $host;
    proxy_set_header Cookie "";
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Port __VESTA_TLS_PORT__;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_hide_header Set-Cookie;
    proxy_connect_timeout 10s;
    proxy_read_timeout 900s;
    proxy_send_timeout 900s;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_pass http://unix:/run/vesta-harbor/proxy.sock;
}
location = /service/token {
    client_max_body_size 64k;
    client_body_timeout 15s;
    limit_conn vesta_harbor_registry 20;
    access_log /var/log/vesta/harbor-registry-access.log vesta_harbor_registry buffer=32k flush=5s;
    proxy_set_header Host $host;
    proxy_set_header Cookie "";
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Port __VESTA_TLS_PORT__;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_hide_header Set-Cookie;
    proxy_connect_timeout 10s;
    proxy_read_timeout 30s;
    proxy_send_timeout 30s;
    proxy_buffering on;
    proxy_request_buffering on;
    proxy_pass http://unix:/run/vesta-harbor/proxy.sock;
}
