class BlockBotScans
  # Paths probed by automated vulnerability scanners (env files, git
  # metadata, WordPress, PHP admin panels, Spring boot actuators, etc.).
  # Matching requests get a tiny 404 from this middleware, so they never
  # reach the Rails router — keeps logs clean and saves a controller hit.
  PATH_RE = %r{
    \A/(?:
      \.env(?:\..*)?              | # .env, .env.local, .env.production, ...
      \.git(?:/.*)?               | # .git/HEAD, .git/config, ...
      \.aws(?:/.*)?               | # .aws/credentials
      \.ssh(?:/.*)?               | # .ssh/id_rsa, etc.
      wp-(?:admin|login|content|includes|json)(?:/.*)?  | # WordPress
      wordpress(?:/.*)?           |
      xmlrpc\.php                 |
      phpmyadmin(?:/.*)?          | # phpmyadmin, pma
      pma(?:/.*)?                 |
      mysql(?:/.*)?               |
      adminer(?:\.php)?           |
      vendor/phpunit(?:/.*)?      | # CVE-2017-9841
      actuator(?:/.*)?            | # Spring boot actuator
      cgi-bin(?:/.*)?             | # generic CGI scans
      \.DS_Store                  |
      web\.config                 |
      composer\.(?:json|lock)     |
      package(?:-lock)?\.json     |
      yarn\.lock                  |
      backup(?:/.*)?              |
      backups?\.(?:zip|tar|gz|sql)
    )\z
  }xi.freeze

  # Anything ending in .php is also a scan — this app is Rails, never serves PHP.
  # Kept separate from PATH_RE so it short-circuits even faster.
  PHP_RE = /\.php\z/i.freeze

  RESPONSE = [
    404,
    { "content-type" => "text/plain; charset=utf-8", "x-blocked" => "bot-scan" },
    ["Not Found\n"]
  ].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    path = env["PATH_INFO"].to_s
    return RESPONSE if PHP_RE.match?(path) || PATH_RE.match?(path)

    @app.call(env)
  end
end
