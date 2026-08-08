# Managed by Vesta. Do not expose any other Harbor route.
location = /v2/ {
    client_max_body_size 0;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Port __VESTA_TLS_PORT__;
    proxy_pass http://unix:/run/vesta-harbor/proxy.sock;
}
location ^~ /v2/ {
    client_max_body_size 0;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Port __VESTA_TLS_PORT__;
    proxy_pass http://unix:/run/vesta-harbor/proxy.sock;
}
location = /service/token {
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Port __VESTA_TLS_PORT__;
    proxy_pass http://unix:/run/vesta-harbor/proxy.sock;
}
