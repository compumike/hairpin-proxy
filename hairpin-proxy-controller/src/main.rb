#!/usr/bin/env ruby
# frozen_string_literal: true

require "k8s-ruby"
require "logger"
require "optparse"
require "socket"

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

  def set_coredns_env_var

    # This function looks up for coredns configmap name from env.
    # If not present, it uses default name coredns
    # Returning CoreDNS CM Variable
    if ENV.key?('COREDNS_IMPORT_CONFIG')
      coredns_import = ENV.fetch(COREDNS_IMPORT_CONFIG)
      @log.info("Info: Core DNS import feature enabled.. Syntax will be similar to import config...")
    else
      coredns_import = false
      @log.info("Info: Core DNS import feature disabled.. Falling back to default syntax")
    end

    if ENV.key?('COREDNS_CONFIGMAP_NAME')
      coredns_cm = ENV.fetch('COREDNS_CONFIGMAP_NAME')
      @log.info("Info: CoreDNS Custom ConfigMap Enabeld.. #{COREDNS_CONFIGMAP_NAME} will be modified for adding rewrite rules...")
    else
      coredns_cm = "coredns"
      @log.info("Info: No COREDNS_CONFIGMAP_NAME Environment Variable found.. Falling back to default configmap 'coredns'")
    end
    return [coredns_import,coredns_cm]
  end

  def fetch_ingress_hosts
    # Return a sorted Array of all unique hostnames mentioned in Ingress spec.tls.hosts blocks, in all namespaces.
    all_ingresses = INGRESS_API_VERSIONS.map { |api_version|
      begin
        @k8s.api(api_version).resource("ingresses").list
      rescue K8s::Error::NotFound, K8s::Error::UndefinedResource
        @log.warn("Warning: Unable to list ingresses in #{api_version}")
        []
      end
    }.flatten
    all_tls_blocks = all_ingresses.map { |r| r.spec.tls }.flatten.compact
    hosts = all_tls_blocks.map(&:hosts).flatten.compact
    hosts.filter! { |host| /\A[A-Za-z0-9.\-_]+\z/.match?(host) }
    hosts.sort.uniq
  end

  def coredns_corefile_with_rewrite_rules(original_corefile, hosts,configmap_import_enabled)
    # Return a String representing the original CoreDNS Corefile, modified to include rewrite rules for each of *hosts.
    # This is an idempotent transformation because our rewrites are labeled with COMMENT_LINE_SUFFIX.

    # Extract base configuration, without our hairpin-proxy rewrites

    cflines = original_corefile.strip.split("\n").reject { |line| line.strip.end_with?(COMMENT_LINE_SUFFIX) }

    # Create rewrite rules
    rewrite_lines = hosts.map { |host| "    rewrite name #{host} #{DNS_REWRITE_DESTINATION} #{COMMENT_LINE_SUFFIX}" }
    
    if configmap_import_enabled = false

      # Inject at the start of the main ".:53 { ... }" configuration block
      main_server_line = cflines.index { |line| line.strip.start_with?(".:53 {") }
      raise "Can't find main server line! '.:53 {' in Corefile" if main_server_line.nil?
      cflines.insert(main_server_line + 1, *rewrite_lines)

      cflines.join("\n")
    else

      # Inject at the start of the main ".:53 { ... }" configuration block
      cflines.insert(0, *rewrite_lines)

      cflines.join("\n")
    end
  end

  def check_and_rewrite_coredns
    @log.info("Polling all Ingress resources and CoreDNS configuration...")
    hosts = fetch_ingress_hosts
    configmap_import_enabled,configmap_name = set_coredns_env_var
    cm = @k8s.api.resource("configmaps", namespace: "kube-system").get(configmap_name)

    if configmap_import_enabled != true
      old_corefile = cm.data.Corefile
    else
      if cm&.data&.has_key?("hairping-proxy.include")
        old_corefile = cm.data['hairping-proxy.include']
      end
    end
      new_corefile = coredns_corefile_with_rewrite_rules(old_corefile, hosts,configmap_type)

    if old_corefile.strip != new_corefile.strip
      @log.info("Corefile has changed! New contents:\n#{new_corefile}\nSending updated ConfigMap to Kubernetes API server...")
      cm.data.Corefile = new_corefile
      @k8s.api.resource("configmaps", namespace: "kube-system").update_resource(cm)
    end
  end

  def dns_rewrite_destination_ip_address
    Addrinfo.ip(DNS_REWRITE_DESTINATION).ip_address
  end

  def etchosts_with_rewrite_rules(original_etchosts, hosts)
    # Returns a String represeting the original /etc/hosts file, modified to include a rule for
    # mapping *hosts to dns_rewrite_destination_ip_address. This handles kubelet and the node's Docker engine,
    # which does not go through CoreDNS.
    # This is an idempotent transformation because our rewrites are labeled with COMMENT_LINE_SUFFIX.

    # Extract base configuration, without our hairpin-proxy rewrites
    our_lines, original_lines = original_etchosts.strip.split("\n").partition { |line| line.strip.end_with?(COMMENT_LINE_SUFFIX) }

    ip = dns_rewrite_destination_ip_address
    hostlist = hosts.join(" ")
    new_rewrite_line = "#{ip}\t#{hostlist} #{COMMENT_LINE_SUFFIX}"

    if our_lines == [new_rewrite_line]
      # Return early so that we're indifferent to the ordering of /etc/hosts lines.
      return original_etchosts
    end

    (original_lines + [new_rewrite_line]).join("\n") + "\n"
  end

  def check_and_rewrite_etchosts(etchosts_path)
    @log.info("Polling all Ingress resources and etchosts file at #{etchosts_path}...")
    hosts = fetch_ingress_hosts

    old_etchostsfile = File.read(etchosts_path)
    new_etchostsfile = etchosts_with_rewrite_rules(old_etchostsfile, hosts)

    if old_etchostsfile.strip != new_etchostsfile.strip
      @log.info("/etc/hosts has changed! New contents:\n#{new_etchostsfile}\nWriting to #{etchosts_path}...")
      File.write(etchosts_path, new_etchostsfile)
    end
  end

  def main_loop
    etchosts_path = nil

    OptionParser.new { |opts|
      opts.on("--etc-hosts ETCHOSTSPATH", "Path to writable /etc/hosts file") do |h|
        etchosts_path = h
        raise "File #{etchosts_path} doesn't exist!" unless File.exist?(etchosts_path)
        raise "File #{etchosts_path} isn't writable!" unless File.writable?(etchosts_path)
      end
    }.parse!

    if etchosts_path && etchosts_path != ""
      @log.info("Starting in /etc/hosts mutation mode on #{etchosts_path}. (Intended to be run as a DaemonSet: one instance per Node.)")
    else
      etchosts_path = nil
      @log.info("Starting in CoreDNS mode. (Indended to be run as a Deployment: one instance per cluster.)")
    end

    @log.info("Starting main_loop with #{POLL_INTERVAL}s polling interval.")
    loop do
      if etchosts_path.nil?
        check_and_rewrite_coredns
      else
        check_and_rewrite_etchosts(etchosts_path)
      end

      sleep(POLL_INTERVAL)
    end
  end
end

HairpinProxyController.new.main_loop if $PROGRAM_NAME == __FILE__
