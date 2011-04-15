require 'FileUtils'
require 'resolv'


def apt(*params)
  # Default apt-get command - reduces any interactivity to the minimum.
  apt_get = "DEBCONF_TERSE='yes' DEBIAN_PRIORITY='critical' DEBIAN_FRONTEND=noninteractive apt-get"

  sudo %Q{sh -c "#{apt_get} --quiet --assume-yes #{params.join(' ')}"}
end

def apt_update
  apt(%w{update})
end

def apt_install(*packages)
  apt(%w{--show-upgraded --force-yes install} + packages)
end

CONFIG_FILES = [
  {:path => "/etc/aliases",           :mode => 0644, :owner => "root:root"},
  {:path => "/etc/hostname",          :mode => 0644, :owner => "root:root"},
  {:path => "/etc/mailname",          :mode => 0644, :owner => "root:root"},
  {:path => "/etc/postfix/generic",   :mode => 0644, :owner => "root:root"},
  {:path => "/etc/postfix/main.cf",   :mode => 0644, :owner => "root:root"},
  {:path => "/etc/opendkim.conf",     :mode => 0644, :owner => "root:root"},
  {:path => "/etc/mail/dkim.key",     :mode => 0440, :owner => "dk-filter:dk-filter"},
  {:path => "/etc/mail/dkim.key.pub", :mode => 0444, :owner => "dk-filter:dk-filter"},
  {:path => "/etc/default/dk-filter", :mode => 0644, :owner => "root:root"},
]

def config_file_paths
  CONFIG_FILES.map {|f| f[:path] }
end

def config_file_paths_without_leading_slash
  config_file_paths.map {|s| s.gsub(/^\//, '')}
end

def mode_string(mode)
  mode.is_a?(Numeric) ? mode.to_s(8) : mode.to_s
end

def backup_dir
  @timestamp ||= Time.now.strftime("%Y%m%d%H%M%S")
  File.expand_path("../../config-#{canonical_hostname}-#{@timestamp}", __FILE__)
end

def config_dir
  File.expand_path("../../config-#{canonical_hostname}", __FILE__)
end

def templates_dir
  File.expand_path("../../templates", __FILE__)
end

def additional_hostnames_expanded
  domains = [canonical_hostname] + (additional_hostnames || []) + ["localhost.localdomain"]
  domains_and_hostnames = domains.inject([]) do |array, domain|
    array << domain
    array << domain.split(/\./).first
  end
  domains_and_hostnames.compact.uniq
end

def dkim_selector
  canonical_hostname.gsub(/\./, '_')
end

def dkim_key
  file_contents = File.read("#{config_dir}/etc/mail/dkim.key.pub")
  /^-----BEGIN PUBLIC KEY-----$(.*)^-----END PUBLIC KEY-----$/m.match(file_contents)[1].gsub(/\s+/, '')
end


set :canonical_hostname,    defer { abort "canonical_hostname not specified" }
set :additional_hostnames,  defer { abort "additional_hostnames not specified" }
set :email_domains,         defer { abort "email_domains not specified" }
set :forwarding_address,    defer { abort "forwarding_address not specified" }
set :envelope_sender,       defer { abort "envelope_sender not specified" }
set :application_user,      defer { abort "application_user not specified" }
set :sudo_user,             defer { abort "sudo_user not specified" }
set :address,               defer { abort "address not specified" }
# TODO: ensure forwarding_address and envelope_sender are included in email domains

set :user, defer { sudo_user }
role(:email) { address }

# Allow capistrano to ask for sudo passwords at the command line prompt.
default_run_options[:pty] = true

namespace :email do
  on :start, "email:load_config"
  task :load_config do
    abort "Please specify CONFIG (e.g., CONFIG=example.com cap setup_email)" unless ENV['CONFIG']

    config_file = File.expand_path("../../config-#{ENV['CONFIG']}.yml", __FILE__)
    abort "Config file '#{config_file}' not found." unless File.exist?(config_file)

    config = YAML.load_file(config_file)
    config.each do |k,v|
      set k.to_sym, v
    end
  end

  task :install_packages, :roles => [:email] do
    # assume Ubuntu/Debian
    apt_update
    apt_install(%w{postfix opendkim dk-filter})
  end

  task :backup_config, :roles => [:email] do
    remote_archive = "/tmp/postfixer.#{Process.pid}"
    local_archive = "#{backup_dir}.tar.gz"
    sudo "tar -czf #{remote_archive} $(ls #{config_file_paths.join(' ')} 2>/dev/null)"
    sudo "chown #{user} #{remote_archive}"
    get remote_archive, local_archive
    sudo "rm #{remote_archive}"
    FileUtils.mkdir_p(backup_dir)
    system("tar -C #{backup_dir} -xzf #{local_archive}") or abort "failed expanding #{local_archive}"
  end

  task :generate_config, :roles => [:email] do
    config_file_paths.each do |path|
      template_file = "#{templates_dir}#{path}.erb"
      if File.exist? template_file
        template = ERB.new(IO.read(template_file), nil, '-')
        rendered_template = template.result(binding)

        output_file = "#{config_dir}#{path}"
        FileUtils.mkdir_p(File.dirname(output_file))
        File.open(output_file, 'w') {|f| f.write rendered_template }
      end
    end

    private_key = "#{config_dir}/etc/mail/dkim.key"
    public_key = "#{config_dir}/etc/mail/dkim.key.pub"
    unless File.exist?(private_key) and File.exist?(public_key)
      FileUtils.mkdir_p("#{config_dir}/etc/mail")
      system("openssl genrsa -out #{private_key} 1024") or abort "failed generating RSA private key #{private_key}"
      system("openssl rsa -in #{private_key} -out #{public_key} -pubout -outform PEM") or abort "failed generating RSA public key #{public_key}"
    end
  end

  task :install_config, :roles => [:email] do
    local_archive = "#{config_dir}.tar.gz"
    remote_archive = "/tmp/postfixer.#{Process.pid}"
    system("tar -C #{config_dir} -czf #{local_archive} #{config_file_paths_without_leading_slash.join(' ')}") or abort "failed creating #{local_archive}"
    put File.open(local_archive).read, remote_archive
    sudo "tar -C / -xzf #{remote_archive}"
    CONFIG_FILES.each do |config_file|
      sudo "chown #{config_file[:owner]} #{config_file[:path]}"
      sudo "chmod #{mode_string(config_file[:mode])} #{config_file[:path]}"
    end
    sudo "rm #{remote_archive}"

    sudo "/usr/bin/newaliases"
    sudo "postmap /etc/postfix/generic"
    sudo "hostname -F /etc/hostname"

    # add user opendkim to groups dk-filter so they can both read the dkim key
    sudo "usermod --append --groups dk-filter opendkim"
  end

  task :restart, :roles => [:email] do
    # NOTE: starting opendkim over a pty fails on Ubuntu 10.10 Maverick
    # Reported 20110415 to Ubuntu package maintainers (https://bugs.launchpad.net/ubuntu/+source/opendkim/+bug/761967)
    # Reported 20110415 to OpenDKIM mailing list (opendkim-users@lists.opendkim.org)
    sudo "/etc/init.d/opendkim restart", :pty => false
    sudo "/etc/init.d/dk-filter restart", :pty => false
    sudo "/etc/init.d/postfix restart"
  end

  task :print_dns, :roles => [:email] do
    puts "For DKIM to work, you will need to add the following DNS entries:\n\n"
    email_domains.each do |domain|
      puts <<-EOF
        #{dkim_selector}._domainkey.#{domain}. IN TXT "v=DKIM1; k=rsa; p=#{dkim_key}"
        _adsp._domainkey.#{domain}.   IN TXT "dkim=unknown;"
        _ssp._domainkey.#{domain}.    IN TXT "dkim=unknown;"
        _policy._domainkey.#{domain}. IN TXT "o=~;"
        _domainkey.#{domain}.         IN TXT "o=~;"

      EOF
    end

    puts "For SPF to work, you will need to add the following DNS entries:\n\n"
    email_domains.each do |domain|
      puts <<-EOF
        spf.#{domain}. IN TXT "v=spf1 a:#{canonical_hostname} include:_spf.google.com ~all"
        #{domain}.     IN TXT "v=spf1 mx include:spf.#{domain} ~all"

      EOF
    end
  end

  task :check_dns, :roles => [:email] do
    warnings = []
    Resolv::DNS.open do |dns|
      cname_resources = dns.getresources canonical_hostname, Resolv::DNS::Resource::IN::CNAME
      found_cname = !cname_resources.empty?
      warnings << "#{canonical_hostname} is a CNAME record" if found_cname
      cname_resources.each do |cname_resource|
        addresses_for_cname = dns.getaddresses cname_resource.name
        puts "CNAME: #{canonical_hostname} => #{cname_resource.name} => #{addresses_for_cname.join(',')}"
      end

      addresses = dns.getaddresses canonical_hostname
      warnings << "Did not find an A record for #{canonical_hostname}" if addresses.empty?
      addresses.each {|address| puts "A: #{canonical_hostname} => #{address}" } unless found_cname

      matched_address = false
      addresses.each do |address|
        dns.getnames(address.to_s).each do |name|
          puts "PTR: #{address} => #{name}"
          matched_address ||= (canonical_hostname == name.to_s)
        end
      end
      warnings << "Forward and reverse DNS mismatch for #{canonical_hostname}" unless matched_address

      # check for SPF and DKIM entries
      email_domains.each do |domain|
        found_spf = false
        txt_resources = dns.getresources domain, Resolv::DNS::Resource::IN::TXT
        txt_resources.each do |txt_resource|
          puts "TXT: #{domain} => \"#{txt_resource.data}\""
          found_spf ||= /\bv=spf1\b/.match(txt_resource.data)
        end
        warnings << "Did not find SPF record #{domain}" unless found_spf

        [
          ["DKIM Key", "#{dkim_selector}._domainkey.#{domain}"],
          ["ADSP policy", "_adsp._domainkey.#{domain}"],
          ["SSP policy", "_ssp._domainkey.#{domain}"],
          ["DKIM policy", "_policy._domainkey.#{domain}"],
          ["DKIM", "_domainkey.#{domain}"],
        ].each do |(description, resource_name)|
          txt_resources = dns.getresources resource_name, Resolv::DNS::Resource::IN::TXT
          txt_resources.each {|txt_resource| puts "TXT: #{resource_name} => \"#{txt_resource.data}\"" }
          warnings << "Did not find #{description} record #{resource_name}" if txt_resources.empty?
        end
      end
    end
    puts warnings.map {|s| "WARNING: #{s}"}
  end

  task :send_test_email, :roles => [:email] do
    email_domains.each do |domain|
      from_address = Capistrano::CLI.ui.ask("Enter an @#{domain} address to send a test email to:")
      remote_email = "/tmp/postfixer.#{Process.pid}"
      put <<-EOF, remote_email
From: #{from_address}
To: check-auth2@verifier.port25.com
Subject: Test Email

hello guy, this is a test email

hug
      EOF
      run "/usr/sbin/sendmail -f #{envelope_sender} -t < #{remote_email}"
      run "rm #{remote_email}"
    end
  end
end
