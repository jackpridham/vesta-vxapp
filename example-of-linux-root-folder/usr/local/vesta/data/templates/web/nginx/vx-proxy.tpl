server {
    listen      %ip%:%proxy_port%;
    server_name %domain_idn% %alias_idn%;
    error_log  /var/log/%web_system%/domains/%domain%.error.log error;

%vx_proxy_host_guard%

%vx_proxy_location_block%

    # vx connection: content begin
    location /error/ {
        alias   %home%/%user%/web/%domain%/document_errors/;
    }

    # vx connection: content end

    location ~ /\.ht    {return 404;}
    location ~ /\.env   {return 404;}
    location ~ /\.svn/  {return 404;}
    location ~ /\.git/  {return 404;}
    location ~ /\.hg/   {return 404;}
    location ~ /\.bzr/  {return 404;}

    disable_symlinks if_not_owner from=%docroot%;

    # vx connection: content begin
    include %home%/%user%/conf/web/nginx.%domain%.conf*;
    # vx connection: content end
}
