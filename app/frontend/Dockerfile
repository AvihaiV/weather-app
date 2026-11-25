# nginx-unprivileged: runs as UID 101 on port 8080, no root needed.
FROM nginxinc/nginx-unprivileged:1.31-alpine@sha256:b5047b9b76845eac124358373c6852377c52e4b05834a47647e955dd91cb8f1e
# Apply Alpine security fixes released after the base image was built, then drop back to non-root.
USER root
RUN apk upgrade --no-cache
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/
# Explicit, not inherited from the base image: swapping the base can never silently make this root.
USER 101:101
