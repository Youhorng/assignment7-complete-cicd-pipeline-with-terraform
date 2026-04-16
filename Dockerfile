FROM nginxinc/nginx-unprivileged:1.29-alpine

# Switch to root briefly to patch OS packages (openssl/libpng/libxml2/libexpat CVEs)
USER root
RUN apk update \
 && apk upgrade --no-cache \
 && rm -rf /var/cache/apk/*

# Drop nginx default config and add ours
COPY --chown=nginx:nginx nginx/default.conf /etc/nginx/conf.d/default.conf

# Copy site assets
COPY --chown=nginx:nginx index.html about.html book.html menu.html /usr/share/nginx/html/
COPY --chown=nginx:nginx css/    /usr/share/nginx/html/css/
COPY --chown=nginx:nginx js/     /usr/share/nginx/html/js/
COPY --chown=nginx:nginx images/ /usr/share/nginx/html/images/
COPY --chown=nginx:nginx fonts/  /usr/share/nginx/html/fonts/

# Drop back to non-root for runtime (satisfies DS-0002)
USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- http://localhost:8080/health || exit 1
