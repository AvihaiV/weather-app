# nginx-unprivileged: runs as UID 101 on port 8080, no root needed.
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/
# Explicit, not inherited from the base image: swapping the base can never silently make this root.
USER 101:101
