# hairpin-proxy

PROXY protocol support for internal-to-LoadBalancer traffic for Kubernetes Ingress users.

If you've had problems with ingress-nginx, cert-manager, LetsEncrypt ACME HTTP01 self-check failures, and the PROXY protocol, read on.

## The PROXY Protocol

If you run a service behind a load balancer, your downstream server will see all connections as originating from the load balancer's IP address. The user's source IP address will be lost and will not be visible to your server. To solve this, the [PROXY protocol](http://www.haproxy.org/download/1.8/doc/proxy-protocol.txt) preserves source addresses on proxied TCP connections by having the load balancer prepend a simple string such as "PROXY TCP4 255.255.255.255 255.255.255.255 65535 65535\r\n" at the beginning of the downstream TCP connection.

Because this injects data at the application-level, the PROXY protocol must be supported on both ends of the connection. Fortunately, this is widely supported already:

- Load balancers such as [AWS ELB](https://aws.amazon.com/blogs/aws/elastic-load-balancing-adds-support-for-proxy-protocol/), [AWS NLB](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-target-groups.html#proxy-protocol), [DigitalOcean Load Balancers](https://www.digitalocean.com/blog/load-balancers-now-support-proxy-protocol/), [GCP Cloud Load Balancing](https://cloud.google.com/load-balancing/docs/tcp/setting-up-tcp#proxy-protocol), and [Linode NodeBalancers](https://www.linode.com/docs/guides/nodebalancer-proxypass-configuration/) support adding the PROXY protocol line to their downstream TCP connections.
- Web servers such as [Apache](https://httpd.apache.org/docs/2.4/mod/mod_remoteip.html#remoteipproxyprotocol), [Caddy](https://github.com/caddyserver/caddy/pull/1349), [Lighttpd](https://redmine.lighttpd.net/projects/lighttpd/wiki/Docs_ModExtForward), and [NGINX](https://docs.nginx.com/nginx/admin-guide/load-balancer/using-proxy-protocol/) support receiving the PROXY protocol line use the passed source IP for access logging and passing it to the application server with an `X-Forwarded-For` HTTP header, where it can be accessed by your backend.

If you configure both your load balancer and web server to send/accept the PROXY protocol, everything just works! Until...

## The Problem

In this case, Kubernetes networking is too smart for its own good. [See upstream Kubernetes issue](https://github.com/kubernetes/kubernetes/issues/66607)

An ingress controller service deploys a LoadBalancer, which is provisioned by your cloud provider. Kubernetes notices the LoadBalancer's external IP address. As an "optimization", kube-proxy on each node writes iptables rules that rewrite all outbound traffic to the LoadBalancer's external IP address to instead be redirected to the cluster-internal Service ClusterIP address. If your cloud load balancer doesn't modify the traffic, then indeed this is a helpful optimization.

However, when you have the PROXY protocol enabled, the external load balancer _does_ modify the traffic, prepending the PROXY line before each TCP connection. If you connect directly to the web server internally, bypassing the external load balancer, then it will receive traffic _without_ the PROXY line. In the case of ingress-nginx with `use-proxy-protocol: "true"`, you'll find that NGINX fails when receiving a bare GET request. As a result, accessing http://your-site/ from inside the cluster fails!

This is particularly a problem when using cert-manager for provisioning SSL certificates. Cert-manager uses HTTP01 validation, and before asking LetsEncrypt to hit http://your-site/some-special-url, it tries to access this URL itself as a self-check. This fails. Cert-manager does not allow you to skip the self-check. As a result, your certificate is never provisioned, even though the verification URL would be perfectly accessible externally. See upstream cert-manager issues: [proxy_protocol mode breaks HTTP01 challenge Check stage](https://github.com/jetstack/cert-manager/issues/466), [http-01 self check failed for domain](https://github.com/jetstack/cert-manager/issues/656), [Self check always fail](https://github.com/jetstack/cert-manager/issues/863) 

## Possible Solutions

There are several ways to solve this problem:

- Modify Kubernetes to not rewrite the external IP address of a LoadBalancer.
- Modify nginx to treat the PROXY line as optional.
- Modify cert-manager to add the PROXY line on its self-check.
- Modify cert-manager to bypass the self-check.

None of these are particularly easy without modifying upstream packages, and the upstream maintainers don't seem eager to address the reported issues linked above.

## The hairpin-proxy Solution

1. hairpin-proxy intercepts and modifies cluster-internal DNS lookups for hostnames that are served by your ingress controller, pointing them to the IP of an internal `hairpin-proxy-haproxy` service instead. (This is managed by `hairpin-proxy-controller`, which simply watches the Kubernetes API for new/modified Ingress resources and updates the CoreDNS ConfigMap when necessary.)
2. The internal `hairpin-proxy-haproxy` service runs a minimal HAProxy instance which is configured to append the PROXY line and forward the traffic on to the internal ingress controller.

As a result, when pod in your cluster (such as cert-manager) try to access http://your-site/, they resolve to the hairpin-proxy, which adds the PROXY line and sends it to your `ingress-nginx`. The NGINX parses the PROXY protocol just as it would if it had come from an external load balancer, so it sees a valid request and handles it identically to external requests.

## Deployment

```shell
kubectl apply -f deploy.yml
```
Coming soon.
