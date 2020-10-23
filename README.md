# hairpin-proxy

PROXY protocol support for internal-to-LoadBalancer traffic for Kubernetes Ingress users, specifically for cert-manager self-checks.

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

However, when you have the PROXY protocol enabled, the external load balancer _does_ modify the traffic, prepending the PROXY line before each TCP connection. If you connect directly to the web server internally, bypassing the external load balancer, then it will receive traffic _without_ the PROXY line. In the case of ingress-nginx with `use-proxy-protocol: "true"`, you'll find that NGINX fails when receiving a bare GET request. As a result, accessing http://subdomain.example.com/ from inside the cluster fails!

This is particularly a problem when using cert-manager for provisioning SSL certificates. Cert-manager uses HTTP01 validation, and before asking LetsEncrypt to hit http://subdomain.example.com/.well-known/acme-challenge/some-special-code, it tries to access this URL itself as a self-check. This fails. Cert-manager does not allow you to skip the self-check. As a result, your certificate is never provisioned, even though the verification URL would be perfectly accessible externally. See upstream cert-manager issues: [proxy_protocol mode breaks HTTP01 challenge Check stage](https://github.com/jetstack/cert-manager/issues/466), [http-01 self check failed for domain](https://github.com/jetstack/cert-manager/issues/656), [Self check always fail](https://github.com/jetstack/cert-manager/issues/863)

## Possible Solutions

There are several ways to solve this problem:

- Modify Kubernetes to not rewrite the external IP address of a LoadBalancer.
- Modify nginx to treat the PROXY line as optional.
- Modify cert-manager to add the PROXY line on its self-check.
- Modify cert-manager to bypass the self-check.

None of these are particularly easy without modifying upstream packages, and the upstream maintainers don't seem eager to address the reported issues linked above.

## The hairpin-proxy Solution

1. hairpin-proxy intercepts and modifies cluster-internal DNS lookups for hostnames that are served by your ingress controller, pointing them to the IP of an internal `hairpin-proxy-haproxy` service instead. (This is managed by `hairpin-proxy-controller`, which simply watches the Kubernetes API for new/modified Ingress resources, examines their `spec.tls.hosts`, and updates the CoreDNS ConfigMap when necessary.)
2. The internal `hairpin-proxy-haproxy` service runs a minimal HAProxy instance which is configured to append the PROXY line and forward the traffic on to the internal ingress controller.

As a result, when pod in your cluster (such as cert-manager) try to access http://your-site/, they resolve to the hairpin-proxy, which adds the PROXY line and sends it to your `ingress-nginx`. The NGINX parses the PROXY protocol just as it would if it had come from an external load balancer, so it sees a valid request and handles it identically to external requests.

## Quick Start Deployment

### Step 0: Confirm that HTTP does NOT work from containers in your cluster

Let's suppose that `http://subdomain.example.com/` is served from your cluster, behind a cloud load balancer with PROXY protocol enabled, and served by an ingress-nginx. You've just tried to add `cert-manager` but found that your certificates are stuck because the self-check is failing.

Get a shell within your cluster and try to access the site to confirm that it isn't working:

```shell
k run my-test-container --image=alpine -it --rm -- /bin/sh
apk add bind-tools curl
dig subdomain.example.com
curl http://subdomain.example.com/
curl http://subdomain.example.com/ --haproxy-protocol
```

The `dig` should show the external load balancer IP address. The `curl` should fail with `Empty reply from server` because NGINX expects the PROXY protocol. However, the second `curl` with `--haproxy-protocol` should succeed, indicating that despite the external-appearing IP address, the traffic is being rewritten by Kubernetes to bypass the external load balancer.

### Step 1: Install hairpin-proxy in your Kubernetes cluster

```shell
kubectl apply -f https://raw.githubusercontent.com/compumike/hairpin-proxy/v0.1.0/deploy.yml
```

If you're using [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) and optionally [cert-manager](https://github.com/jetstack/cert-manager), it will work out of the box.

### Step 2: Confirm that your CoreDNS configuration was updated

```shell
kubectl get configmap -n kube-system coredns -o=jsonpath='{.data.Corefile}'
```

Once the hairpin-proxy-controller pod starts, you should immediately see one [rewrite](https://coredns.io/plugins/rewrite/) line per TLS-enabled ingress host, such as:

```
rewrite name subdomain.example.com hairpin-proxy.hairpin-proxy.svc.cluster.local # Added by hairpin-proxy
```

Note that the comment `# Added by hairpin-proxy` is used to prevent hairpin-proxy-controller from modifying any other rewrites you may have.

### Step 3: Confirm that your DNS has propagated and that HTTP now works from containers in your cluster

```shell
k run my-test-container --image=alpine -it --rm -- /bin/sh
apk add bind-tools curl
dig subdomain.example.com
dig hairpin-proxy.hairpin-proxy.svc.cluster.local
curl http://subdomain.example.com/
```

This time, the first `dig` should show an internal service IP address (generally `10.x.y.z`), matching the second `dig`. This time, the `curl` should succeed.

NOTE: CoreDNS is a cache, so even if you see the `rewrite` rules in Step 2, it will take another minute or two before the queries resolve correctly. Be patient. You may wish to `watch -n 1 dig subdomain.example.com` to see when this changeover happens.

At this point, cert-manager's self-check will pass, and you'll get valid LetsEncrypt certificates within a few minutes.
