FROM haproxy:2.3-alpine

EXPOSE 80
EXPOSE 443

# By default, forward all HTTP requests to an ingress-nginx.
# If using a different ingress controller, you may override TARGET_SERVER at runtime.
ENV TARGET_SERVER=ingress-nginx-controller.ingress-nginx.svc.cluster.local

COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
