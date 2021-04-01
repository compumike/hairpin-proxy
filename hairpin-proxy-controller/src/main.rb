#!/usr/bin/env ruby
# frozen_string_literal: true

require "k8s-ruby"
require "logger"

class HairpinProxyController
  COMMENT_LINE_SUFFIX = "# Added by hairpin-proxy"
  DNS_REWRITE_DESTINATION = "hairpin-proxy.hairpin-proxy.svc.cluster.local"
  POLL_INTERVAL = ENV.fetch("POLL_INTERVAL", "15").to_i.clamp(1..)

  # Kubernetes <= 1.18 puts Ingress in "extensions/v1beta1"
  # Kubernetes >= 1.19 puts Ingress in "networking.k8s.io/v1"
  # (We search both for maximum compatibility.)
  INGRESS_API_VERSIONS = ["extensions/v1beta1", "networking.k8s.io/v1"].freeze

  def initialize
    @k8s = K8s::Client.in_cluster_config

    STDOUT.sync = true
    @log = Logger.new(STDOUT)
  end

  def fetch_ingress_hosts
    # Return a sorted Array of all unique hostnames mentioned in Ingress spec.tls.hosts blocks, in all namespaces.
    all_ingresses = INGRESS_API_VERSIONS.map { |api_version|
      begin
        @k8s.api(api_version).resource("ingresses").list
      rescue K8s::Error::NotFound
        @log.warn("Warning: Unable to list ingresses in #{api_version}")
        []
      end
    }.flatten
    all_tls_blocks = all_ingresses.map { |r| r.spec.tls }.flatten.compact
    all_tls_blocks.map(&:hosts).flatten.compact.sort.uniq
  end

  def coredns_corefile_with_rewrite_rules(original_corefile, hosts)
    # Return a String representing the original CoreDNS Corefile, modified to include rewrite rules for each of *hosts.
    # This is an idempotent transformation because our rewrites are labeled with COMMENT_LINE_SUFFIX.

    # Extract base configuration, without our hairpin-proxy rewrites
    cflines = original_corefile.strip.split("\n").reject { |line| line.strip.end_with?(COMMENT_LINE_SUFFIX) }

    # Create rewrite rules
    rewrite_lines = hosts.map { |host| "    rewrite name #{host} #{DNS_REWRITE_DESTINATION} #{COMMENT_LINE_SUFFIX}" }

    # Inject at the start of the main ".:53 { ... }" configuration block
    main_server_line = cflines.index { |line| line.strip.start_with?(".:53 {") }
    raise "Can't find main server line! '.:53 {' in Corefile" if main_server_line.nil?
    cflines.insert(main_server_line + 1, *rewrite_lines)

    cflines.join("\n")
  end

  def check_and_rewrite_coredns
    @log.info("Polling all Ingress resources and CoreDNS configuration...")
    hosts = fetch_ingress_hosts
    cm = @k8s.api.resource("configmaps", namespace: "kube-system").get("coredns")

    old_corefile = cm.data.Corefile
    new_corefile = coredns_corefile_with_rewrite_rules(old_corefile, hosts)

    if old_corefile.strip != new_corefile.strip
      @log.info("Corefile has changed! New contents:\n#{new_corefile}\nSending updated ConfigMap to Kubernetes API server...")
      cm.data.Corefile = new_corefile
      @k8s.api.resource("configmaps", namespace: "kube-system").update_resource(cm)
    end
  end

  def main_loop
    @log.info("Starting main_loop with #{POLL_INTERVAL}s polling interval.")
    loop do
      check_and_rewrite_coredns

      sleep(POLL_INTERVAL)
    end
  end
end

HairpinProxyController.new.main_loop if $PROGRAM_NAME == __FILE__
