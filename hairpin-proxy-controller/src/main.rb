#!/usr/bin/env ruby
# frozen_string_literal: true

STDOUT.sync = true

require "k8s-client"

def ingress_hosts(k8s)
  all_ingresses = k8s.api("extensions/v1beta1").resource("ingresses").list

  all_tls_blocks = all_ingresses.map { |r| r.spec.tls }.flatten.compact

  all_tls_blocks.map(&:hosts).flatten.compact.sort.uniq
end

def rewrite_coredns_corefile(cf, hosts)
  cflines = cf.strip.split("\n").reject { |line| line.strip.end_with?("# Added by hairpin-proxy") }

  main_server_line = cflines.index { |line| line.strip.start_with?(".:53 {") }
  raise "Can't find main server line! '.:53 {' in Corefile" if main_server_line.nil?

  rewrite_lines = hosts.map { |host| "    rewrite name #{host} hairpin-proxy.hairpin-proxy.svc.cluster.local # Added by hairpin-proxy" }

  cflines.insert(main_server_line + 1, *rewrite_lines)

  cflines.join("\n")
end

def main
  client = K8s::Client.in_cluster_config

  loop do
    puts "#{Time.now}: Fetching..."

    hosts = ingress_hosts(client)
    cm = client.api.resource("configmaps", namespace: "kube-system").get("coredns")

    old_corefile = cm.data.Corefile
    new_corefile = rewrite_coredns_corefile(old_corefile, hosts)

    if old_corefile.strip != new_corefile.strip
      puts "#{Time.now}: Corefile changed!"
      puts new_corefile

      puts "#{Time.now}: Updating ConfigMap."
      cm.data.Corefile = new_corefile
      client.api.resource("configmaps", namespace: "kube-system").update_resource(cm)
    end

    sleep(15)
  end
end

main
