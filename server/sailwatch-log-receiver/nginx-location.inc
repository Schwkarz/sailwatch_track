# Included from inside the existing port-80 server block.
location = /sailwatch-log/health {
    proxy_pass http://172.17.0.1:18091/health;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

location = /sailwatch-log/upload {
    client_max_body_size 9m;
    client_body_timeout 45s;
    proxy_pass http://172.17.0.1:18091/upload;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Authorization $http_authorization;
    proxy_set_header X-SailWatch-File $http_x_sailwatch_file;
    proxy_set_header X-SailWatch-Run-Id $http_x_sailwatch_run_id;
    proxy_set_header X-SailWatch-Device $http_x_sailwatch_device;
    proxy_request_buffering off;
    proxy_buffering off;
}
