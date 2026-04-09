FROM nginx:1.27-alpine

# Drop nginx default config and add ours
COPY nginx/default.conf /etc/nginx/conf.d/default.conf

# Copy site assets
COPY index.html about.html book.html menu.html /usr/share/nginx/html/
COPY css/    /usr/share/nginx/html/css/
COPY js/     /usr/share/nginx/html/js/
COPY images/ /usr/share/nginx/html/images/
COPY fonts/  /usr/share/nginx/html/fonts/

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- http://localhost/health || exit 1
