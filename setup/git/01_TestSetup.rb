test_name "Install puppet and facter on target machines..."

SourcePath = "/opt/puppet-git-repos"
GitHub     = 'git://github.com/puppetlabs'
IsURI      = %r{^[^:]+://}
 
step "Parse Opts"
if options[:puppet] =~ IsURI then
  repo, rev = options[:puppet].split('#', 2)
  PuppetRepo = repo
  PuppetRev  = rev || 'HEAD'
else
  PuppetRepo = "#{GitHub}/puppet.git"
  PuppetRev  = options[:puppet]
end

if options[:facter] =~ IsURI then
  repo, rev = options[:facter].split('#', 2)
  FacterRepo = repo
  FacterRev  = rev || 'HEAD'
else
  FacterRepo = "#{GitHub}/facter.git"
  FacterRev  = options[:facter]
end

def install_from_git(host, package, repo, revision)
  step "Clone #{repo}"
  on host, "cd #{SourcePath} && git clone #{repo}"

  step "Check out the revision #{revision}"
  if revision =~ /master/ then    # change check cmd if branch exists
    on host, "cd #{SourcePath}/#{package} && git checkout #{revision}"
  else
    on host, "cd #{SourcePath}/#{package} && git checkout -b #{revision}"
  end

  step "Install #{package} on the system"
  on host, "cd #{SourcePath}/#{package} && ruby ./install.rb"
end

hosts.each do |host|
  step "Clean and create #{SourcePath}"
  on host, "rm -rf #{SourcePath} && mkdir -vp #{SourcePath}"

  install_from_git host, :facter, FacterRepo, FacterRev
  install_from_git host, :puppet, PuppetRepo, PuppetRev

  step "grab git repo versions"
  version = {}
  [:puppet, :facter].each do |package|
    on host, "cd /opt/puppet-git-repos/#{package} && git describe" do
      version[package] = stdout.chomp
    end
  end
  config[:version] = version

  step "Create required users and groups"
  on host, "getent group puppet || groupadd puppet"
  on host, "getent passwd puppet || useradd puppet -g puppet -G puppet"

  step "REVISIT: Work around bug #5794 not creating reports as required"
  on host, "mkdir -vp /tmp/reports && chown -v puppet:puppet /tmp/reports"
end