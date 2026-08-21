FROM nginx:1

COPY nginx/docker-entrypoint.d /docker-entrypoint.d/
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/templates /etc/nginx/templates/

# Recommended SSL config
COPY nginx/options-ssl-nginx.conf /etc/ssl/options-ssl-nginx.conf
COPY nginx/ssl-dhparams.pem /etc/ssl/ssl-dhparams.pem

COPY ssl /etc/nginx/ssl

RUN chmod -R a+x docker-entrypoint.d
