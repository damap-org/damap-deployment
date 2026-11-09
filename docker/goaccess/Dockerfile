FROM allinurl/goaccess:1.10.2

COPY exclude_routes.txt /etc/goaccess/exclude_routes.txt
COPY docker-entrypoint.sh /

ENTRYPOINT ["/bin/sh", "/docker-entrypoint.sh"]
