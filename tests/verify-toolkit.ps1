param(
    [ValidateSet('scaffold', 'compose', 'proxy', 'landing', 'docs', 'runtime')]
    [string]$Suite = 'scaffold'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$env:TZ = if ($env:TZ) { $env:TZ } else { 'America/New_York' }

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-RepoPath {
    param([string]$RelativePath)
    return Join-Path $RepoRoot $RelativePath
}

function Get-ComposeConfig {
    param(
        [string[]]$Files
    )

    $composeArgs = @()
    foreach ($file in $Files) {
        $composeArgs += '-f'
        $composeArgs += (Get-RepoPath $file)
    }

    Push-Location $RepoRoot
    try {
        $output = docker compose @composeArgs config --format json
    }
    finally {
        Pop-Location
    }

    return $output | ConvertFrom-Json -Depth 100
}

function Test-Scaffold {
    $requiredFiles = @(
        '.gitignore',
        '.env.example',
        'docker-compose.yml',
        'landing\index.html',
        'landing\nginx.conf',
        'README.md'
    )

    foreach ($relativePath in $requiredFiles) {
        $fullPath = Get-RepoPath $relativePath
        Assert-True (Test-Path $fullPath) "Expected required file '$relativePath' to exist."
    }

    $gitignoreLines = Get-Content (Get-RepoPath '.gitignore')
    Assert-True ($gitignoreLines -contains '.env') "Expected .gitignore to ignore '.env'."
}

function Test-Compose {
    $localCompose = Get-RepoPath 'docker-compose.local.yml'
    Assert-True (Test-Path $localCompose) "Expected local override file 'docker-compose.local.yml' to exist."

    $baseConfig = Get-ComposeConfig -Files @('docker-compose.yml')

    foreach ($serviceName in @('toolkit-landing', 'omni-tools', 'cyberchef', 'it-tools')) {
        Assert-True ($null -ne $baseConfig.services.$serviceName) "Expected service '$serviceName' in docker-compose.yml."
        Assert-True ($baseConfig.services.$serviceName.restart -eq 'unless-stopped') "Expected '$serviceName' to use restart: unless-stopped."
        Assert-True (-not $baseConfig.services.$serviceName.ports) "Expected '$serviceName' to have no host ports in docker-compose.yml."
    }

    Assert-True ($baseConfig.services.'toolkit-landing'.image -eq 'nginx:alpine') "Expected toolkit-landing to use nginx:alpine."
    Assert-True ($baseConfig.services.'cyberchef'.image -eq 'ghcr.io/gchq/cyberchef:latest') "Expected cyberchef to use the official ghcr.io/gchq/cyberchef:latest image."
    Assert-True (-not $baseConfig.services.'it-tools'.environment.BASE_URL) "Expected it-tools to have no BASE_URL set (it now runs at /)."
    $toolkitLandingNetworks = $baseConfig.services.'toolkit-landing'.networks.PSObject.Properties.Name | Sort-Object
    Assert-True (($toolkitLandingNetworks -join ',') -eq 'nginx-proxy,toolkit-internal') "Expected toolkit-landing on both networks."

    foreach ($serviceName in @('omni-tools', 'cyberchef', 'it-tools')) {
        $serviceNetworks = $baseConfig.services.$serviceName.networks.PSObject.Properties.Name | Sort-Object
        Assert-True (($serviceNetworks -join ',') -eq 'toolkit-internal') "Expected '$serviceName' on toolkit-internal only."
    }

    Assert-True ($baseConfig.networks.'nginx-proxy'.external -eq $true) "Expected nginx-proxy network to be external."
    Assert-True ($baseConfig.networks.'toolkit-internal'.driver -eq 'bridge') "Expected toolkit-internal network to use the bridge driver."

    $toolkitLandingVolumes = $baseConfig.services.'toolkit-landing'.volumes
    $indexMount = $toolkitLandingVolumes | Where-Object { $_.target -eq '/usr/share/nginx/html/index.html' }
    $nginxMount = $toolkitLandingVolumes | Where-Object { $_.target -eq '/etc/nginx/conf.d/default.conf' }
    Assert-True ($null -ne $indexMount -and $indexMount.read_only) "Expected toolkit-landing to mount landing/index.html read-only."
    Assert-True ($null -ne $nginxMount -and $nginxMount.read_only) "Expected toolkit-landing to mount landing/nginx.conf read-only."

    $localConfig = Get-ComposeConfig -Files @('docker-compose.yml', 'docker-compose.local.yml')
    $toolkitLandingPorts = @($localConfig.services.'toolkit-landing'.ports)
    $localhostPort = $toolkitLandingPorts | Where-Object { $_.published -eq '8080' -and $_.target -eq 80 }
    Assert-True ($null -ne $localhostPort) "Expected local override to expose toolkit-landing on 8080."
    Assert-True ($localConfig.networks.'nginx-proxy'.external -ne $true) "Expected local override to avoid requiring a pre-existing external nginx-proxy network."
    foreach ($serviceName in @('omni-tools', 'cyberchef', 'it-tools')) {
        Assert-True (-not $localConfig.services.$serviceName.ports) "Expected '$serviceName' to remain unexposed in local override."
    }
}

function Test-Proxy {
    $nginxConfigPath = Get-RepoPath 'landing\nginx.conf'
    $nginxConfig = Get-Content $nginxConfigPath -Raw

    # X-Forwarded-Proto → redirect-safe scheme map
    Assert-True ($nginxConfig -match '(?ms)map \$http_x_forwarded_proto \$redirect_scheme \{.*default \$http_x_forwarded_proto;.*""\s+\$scheme;.*\}') "Expected nginx config to map forwarded HTTPS to a redirect-safe scheme."

    # Dynamic subdomain helper maps
    Assert-True ($nginxConfig -match 'map \$http_host \$omni_host') "Expected nginx config to define an \$omni_host map for subdomain-aware redirects."
    Assert-True ($nginxConfig -match 'map \$http_host \$it_host') "Expected nginx config to define an \$it_host map for subdomain-aware redirects."

    Assert-True ($nginxConfig -match '(?m)^\s*listen\s+80;') "Expected nginx to listen on port 80."

    # Named server blocks for each host
    Assert-True ($nginxConfig -match 'server_name\s+tools\.n8-g\.com\s+tools\.localtest\.me;') "Expected tools server block with server_name tools.n8-g.com tools.localtest.me."
    Assert-True ($nginxConfig -match 'server_name\s+omni\.tools\.n8-g\.com\s+omni\.tools\.localtest\.me;') "Expected omni.tools server block with server_name omni.tools.n8-g.com omni.tools.localtest.me."
    Assert-True ($nginxConfig -match 'server_name\s+it\.tools\.n8-g\.com\s+it\.tools\.localtest\.me;') "Expected it.tools server block with server_name it.tools.n8-g.com it.tools.localtest.me."

    # Landing page served from filesystem on the tools host
    Assert-True ($nginxConfig -match '(?m)^\s*root\s+/usr/share/nginx/html;') "Expected nginx root to serve the landing page."
    Assert-True ($nginxConfig -match '(?m)^\s*index\s+index\.html;') "Expected nginx to serve index.html."

    # Legacy redirects on tools host forward to the correct subdomains using $redirect_scheme
    Assert-True ($nginxConfig -match '(?ms)location\s+/omni/\s*\{.*return\s+301\s+\$redirect_scheme://\$omni_host/;') "Expected legacy /omni/ redirect to \$omni_host subdomain using \$redirect_scheme."
    Assert-True ($nginxConfig -match '(?ms)location\s+/it-tools/\s*\{.*return\s+301\s+\$redirect_scheme://\$it_host/;') "Expected legacy /it-tools/ redirect to \$it_host subdomain using \$redirect_scheme."

    # CyberChef remains path-based on the tools host
    Assert-True ($nginxConfig -match '(?ms)location\s+/cyberchef/\s*\{.*proxy_pass\s+http://cyberchef:8080/;') "Expected CyberChef proxy block at /cyberchef/ targeting http://cyberchef:8080/."

    # Omni Tools and IT Tools proxied at / on their respective server blocks
    Assert-True ($nginxConfig -match 'proxy_pass\s+http://omni-tools:80/;') "Expected proxy_pass to http://omni-tools:80/ in the omni.tools server block."
    Assert-True ($nginxConfig -match 'proxy_pass\s+http://it-tools:80/;') "Expected proxy_pass to http://it-tools:80/ in the it.tools server block."

    foreach ($header in @(
        'proxy_set_header\s+Host\s+\$host;',
        'proxy_set_header\s+X-Real-IP\s+\$remote_addr;',
        'proxy_set_header\s+X-Forwarded-For\s+\$proxy_add_x_forwarded_for;',
        'proxy_set_header\s+X-Forwarded-Proto\s+\$scheme;'
    )) {
        Assert-True ($nginxConfig -match $header) "Expected nginx config to include proxy_set_header directive '$header'."
    }

    Assert-True ($nginxConfig -match '(?m)^\s*access_log\s+/dev/stdout;') "Expected nginx access logs on stdout."
    Assert-True ($nginxConfig -match '(?m)^\s*error_log\s+/dev/stderr\s+warn;') "Expected nginx error logs on stderr."

    $repoRootForDocker = $RepoRoot -replace '\\', '/'
    $dockerArgs = @(
        'run', '--rm',
        '--add-host', 'omni-tools:127.0.0.1',
        '--add-host', 'cyberchef:127.0.0.1',
        '--add-host', 'it-tools:127.0.0.1',
        '-v', "${repoRootForDocker}/landing/nginx.conf:/etc/nginx/conf.d/default.conf:ro",
        'nginx:alpine',
        'nginx', '-t'
    )
    $null = docker @dockerArgs
    Assert-True ($LASTEXITCODE -eq 0) "Expected nginx -t to accept landing/nginx.conf."
}

function Test-Landing {
    $indexPath = Get-RepoPath 'landing\index.html'
    $indexHtml = Get-Content $indexPath -Raw

    Assert-True ($indexHtml -match '<title>\s*Tools\s*</title>') "Expected landing page title to be 'Tools'."
    Assert-True ($indexHtml -match '<style>') "Expected landing page to include inline CSS."
    Assert-True ($indexHtml -notmatch '<script\b') "Expected landing page to avoid JavaScript frameworks."
    Assert-True ($indexHtml -notmatch 'https?://') "Expected landing page to avoid external CDN dependencies."

    $links = @(
        @{ Label = 'Omni Tools'; Href = '/omni/'; Description = 'General-purpose browser tools' },
        @{ Label = 'CyberChef'; Href = '/cyberchef/'; Description = 'Encoding, decoding, encryption, data analysis' },
        @{ Label = 'IT Tools'; Href = '/it-tools/'; Description = 'Developer utilities: tokens, hashes, formatters' }
    )

    foreach ($link in $links) {
        $pattern = '(?ms)<a[^>]*href="' + [regex]::Escape($link.Href) + '"[^>]*target="_blank"[^>]*>.*?' +
            [regex]::Escape($link.Label) + '.*?' + [regex]::Escape($link.Description) + '.*?</a>'
        Assert-True ($indexHtml -match $pattern) "Expected landing page card for '$($link.Label)' linking to '$($link.Href)'."
    }
}

function Test-Docs {
    $readme = Get-Content (Get-RepoPath 'README.md') -Raw

    foreach ($section in @(
        '## Repository Structure',
        '## Local Development',
        '## Production Notes',
        '## Verification'
    )) {
        Assert-True ($readme -match [regex]::Escape($section)) "Expected README section '$section'."
    }

    foreach ($snippet in @(
        'Copy `.env.example` to `.env`',
        'docker compose -f docker-compose.yml -f docker-compose.local.yml up -d',
        'http://tools.localtest.me:8080/',
        'http://omni.tools.localtest.me:8080/',
        'http://it.tools.localtest.me:8080/',
        'http://tools.localtest.me:8080/cyberchef/',
        'tools.n8-g.com',
        'omni.tools.n8-g.com',
        'it.tools.n8-g.com',
        'toolkit-landing',
        'docker compose config',
        'docker ps',
        'docker network inspect nginx-proxy'
    )) {
        Assert-True ($readme -match [regex]::Escape($snippet)) "Expected README to mention '$snippet'."
    }
}

function Test-Runtime {
    # Landing page on the tools host
    $landingHtml = (curl.exe -s http://tools.localtest.me:8080/) -join "`n"
    Assert-True ($landingHtml -match '<title>\s*Tools\s*</title>') "Expected tools.localtest.me:8080/ to serve the landing page."

    # CyberChef remains path-based on the tools host
    $cyberchefHtml = (curl.exe -s http://tools.localtest.me:8080/cyberchef/) -join "`n"
    Assert-True ($cyberchefHtml -match '(?i)cyberchef') "Expected tools.localtest.me:8080/cyberchef/ to return CyberChef content."

    # Omni Tools on its own subdomain
    $omniHtml = (curl.exe -s http://omni.tools.localtest.me:8080/) -join "`n"
    Assert-True ((-not [string]::IsNullOrWhiteSpace($omniHtml)) -and ($omniHtml -match '(?i)<html')) "Expected omni.tools.localtest.me:8080/ to return an HTML page."

    # IT Tools on its own subdomain
    $itHtml = (curl.exe -s http://it.tools.localtest.me:8080/) -join "`n"
    Assert-True ((-not [string]::IsNullOrWhiteSpace($itHtml)) -and ($itHtml -match '(?i)<html')) "Expected it.tools.localtest.me:8080/ to return an HTML page."

    # Legacy /omni/ path on tools host redirects to omni subdomain
    $omniRedirectCode = (curl.exe -s -o 'NUL' -w '%{http_code}' http://tools.localtest.me:8080/omni/) -join ''
    Assert-True ($omniRedirectCode -eq '301') "Expected tools.localtest.me:8080/omni/ to return 301 redirect to the omni subdomain."

    $omniRedirectHeaders = (curl.exe -s -I http://tools.localtest.me:8080/omni/) -join "`n"
    Assert-True ($omniRedirectHeaders -match '(?i)location:\s*http://omni\.tools\.localtest\.me:8080/') "Expected /omni/ redirect Location to point to omni.tools.localtest.me:8080/."

    # Legacy /it-tools/ path on tools host redirects to it subdomain
    $itRedirectCode = (curl.exe -s -o 'NUL' -w '%{http_code}' http://tools.localtest.me:8080/it-tools/) -join ''
    Assert-True ($itRedirectCode -eq '301') "Expected tools.localtest.me:8080/it-tools/ to return 301 redirect to the it subdomain."

    $itRedirectHeaders = (curl.exe -s -I http://tools.localtest.me:8080/it-tools/) -join "`n"
    Assert-True ($itRedirectHeaders -match '(?i)location:\s*http://it\.tools\.localtest\.me:8080/') "Expected /it-tools/ redirect Location to point to it.tools.localtest.me:8080/."
}

switch ($Suite) {
    'scaffold' { Test-Scaffold }
    'compose' { Test-Compose }
    'proxy' { Test-Proxy }
    'landing' { Test-Landing }
    'docs' { Test-Docs }
    'runtime' { Test-Runtime }
}

Write-Host "PASS: $Suite"
