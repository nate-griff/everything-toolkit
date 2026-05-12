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
        'landing\nginx.conf.template',
        'parsel\Dockerfile',
        'stegg\Dockerfile',
        'unfurl\Dockerfile',
        'unfurl\unfurl.ini',
        'README.md',
        'tests\verify-toolkit.ps1',
        'tests\verify-toolkit.sh'
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

    foreach ($serviceName in @('toolkit-landing', 'omni-tools', 'cyberchef', 'it-tools', 'parsel', 'stegg', 'network', 'pb', 'unfurl')) {
        Assert-True ($null -ne $baseConfig.services.$serviceName) "Expected service '$serviceName' in docker-compose.yml."
        Assert-True ($baseConfig.services.$serviceName.restart -eq 'unless-stopped') "Expected '$serviceName' to use restart: unless-stopped."
        Assert-True (-not $baseConfig.services.$serviceName.ports) "Expected '$serviceName' to have no host ports in docker-compose.yml."
    }

    Assert-True ($baseConfig.services.'toolkit-landing'.image -eq 'nginx:alpine') "Expected toolkit-landing to use nginx:alpine."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$baseConfig.services.'toolkit-landing'.environment.ROOT_DOMAIN)) "Expected toolkit-landing to receive ROOT_DOMAIN from the environment."
    Assert-True ($baseConfig.services.'cyberchef'.image -eq 'ghcr.io/gchq/cyberchef:latest') "Expected cyberchef to use the official ghcr.io/gchq/cyberchef:latest image."
    Assert-True (-not $baseConfig.services.'it-tools'.environment.BASE_URL) "Expected it-tools to have no BASE_URL set (it now runs at /)."
    $unfurlBuildContext = [string]$baseConfig.services.'unfurl'.build.context
    Assert-True ($unfurlBuildContext -match '(^|[\\/])unfurl$') "Expected unfurl to build from the local unfurl directory."
    Assert-True ($baseConfig.services.'unfurl'.build.dockerfile -eq 'Dockerfile') "Expected unfurl to use the upstream Dockerfile."
    $toolkitLandingNetworks = $baseConfig.services.'toolkit-landing'.networks.PSObject.Properties.Name | Sort-Object
    Assert-True (($toolkitLandingNetworks -join ',') -eq 'nginx-proxy,toolkit-internal') "Expected toolkit-landing on both networks."

    foreach ($serviceName in @('omni-tools', 'cyberchef', 'it-tools', 'parsel', 'stegg', 'network', 'pb', 'unfurl')) {
        $serviceNetworks = $baseConfig.services.$serviceName.networks.PSObject.Properties.Name | Sort-Object
        Assert-True (($serviceNetworks -join ',') -eq 'toolkit-internal') "Expected '$serviceName' on toolkit-internal only."
    }

    Assert-True ($baseConfig.networks.'nginx-proxy'.external -eq $true) "Expected nginx-proxy network to be external."
    Assert-True ($baseConfig.networks.'toolkit-internal'.driver -eq 'bridge') "Expected toolkit-internal network to use the bridge driver."

    $toolkitLandingVolumes = $baseConfig.services.'toolkit-landing'.volumes
    $indexMount = $toolkitLandingVolumes | Where-Object { $_.target -eq '/usr/share/nginx/html/index.html' }
    $templateMount = $toolkitLandingVolumes | Where-Object { $_.target -eq '/etc/nginx/templates/default.conf.template' }
    $nginxMount = $toolkitLandingVolumes | Where-Object { $_.target -eq '/etc/nginx/conf.d/default.conf' }
    Assert-True ($null -ne $indexMount -and $indexMount.read_only) "Expected toolkit-landing to mount landing/index.html read-only."
    Assert-True ($null -ne $templateMount -and $templateMount.read_only) "Expected toolkit-landing to mount an nginx template read-only."
    Assert-True ($null -eq $nginxMount) "Expected toolkit-landing to stop mounting a static landing/nginx.conf into conf.d/default.conf."
    $unfurlConfigMount = $baseConfig.services.'unfurl'.volumes | Where-Object { $_.target -eq '/unfurl/unfurl.ini' }
    Assert-True ($null -ne $unfurlConfigMount -and $unfurlConfigMount.read_only) "Expected unfurl to mount unfurl/unfurl.ini read-only."
    $pbDataMount = $baseConfig.services.'pb'.volumes | Where-Object { $_.target -eq '/app/microbin_data' }
    Assert-True ($null -ne $pbDataMount) "Expected pb to mount persistent storage at /app/microbin_data."
    Assert-True ([string]$baseConfig.services.'network'.environment.PORT -eq '3000') "Expected network to expose its upstream app on port 3000."
    Assert-True ([string]$baseConfig.services.'pb'.environment.MICROBIN_PORT -eq '8080') "Expected pb to expose MicroBin on port 8080."
    $unfurlDockerfile = Get-Content (Get-RepoPath 'unfurl\Dockerfile') -Raw
    Assert-True ($unfurlDockerfile -match 'git clone https://github\.com/RyanDFIR/unfurl /unfurl') "Expected unfurl Dockerfile to clone the RyanDFIR/unfurl repository during build."
    Assert-True ($unfurlDockerfile -match 'git checkout 2d2dac375433d2a7fbeede2d25c5f19b68d4d244') "Expected unfurl Dockerfile to pin the upstream checkout to the planned commit."

    $localConfig = Get-ComposeConfig -Files @('docker-compose.yml', 'docker-compose.local.yml')
    $toolkitLandingPorts = @($localConfig.services.'toolkit-landing'.ports)
    $localhostPort = $toolkitLandingPorts | Where-Object { $_.published -eq '8080' -and $_.target -eq 80 }
    Assert-True ($null -ne $localhostPort) "Expected local override to expose toolkit-landing on 8080."
    Assert-True ($localConfig.networks.'nginx-proxy'.external -ne $true) "Expected local override to avoid requiring a pre-existing external nginx-proxy network."
    foreach ($serviceName in @('omni-tools', 'cyberchef', 'it-tools', 'parsel', 'stegg', 'network', 'pb', 'unfurl')) {
        Assert-True (-not $localConfig.services.$serviceName.ports) "Expected '$serviceName' to remain unexposed in local override."
    }
}

function Test-Proxy {
    $nginxConfigPath = Get-RepoPath 'landing\nginx.conf.template'
    $nginxConfig = Get-Content $nginxConfigPath -Raw

    # X-Forwarded-Proto → redirect-safe scheme map
    Assert-True ($nginxConfig -match '(?ms)map \$http_x_forwarded_proto \$redirect_scheme \{.*default \$http_x_forwarded_proto;.*""\s+\$scheme;.*\}') "Expected nginx config to map forwarded HTTPS to a redirect-safe scheme."
    Assert-True ($nginxConfig -match 'ROOT_DOMAIN') "Expected nginx template to use ROOT_DOMAIN instead of a hard-coded production domain."
    Assert-True ($nginxConfig -notmatch 'n8-g\.com') "Expected nginx template to avoid hard-coded n8-g.com references."

    # Dynamic subdomain helper maps
    Assert-True ($nginxConfig -match 'map \$http_host \$omni_host') "Expected nginx config to define an \$omni_host map for subdomain-aware redirects."
    Assert-True ($nginxConfig -match 'map \$http_host \$it_host') "Expected nginx config to define an \$it_host map for subdomain-aware redirects."
    Assert-True ($nginxConfig -match 'map \$http_host \$unfurl_host') "Expected nginx config to define an \$unfurl_host map for subdomain-aware redirects."
    Assert-True ($nginxConfig -match 'map \$http_host \$parsel_host') "Expected nginx config to define a \$parsel_host map for subdomain-aware redirects."
    Assert-True ($nginxConfig -match 'map \$http_host \$stegg_host') "Expected nginx config to define a \$stegg_host map for subdomain-aware redirects."
    Assert-True ($nginxConfig -match 'map \$http_host \$network_host') "Expected nginx config to define a \$network_host map for subdomain-aware redirects."
    Assert-True ($nginxConfig -match 'map \$http_host \$pb_host') "Expected nginx config to define a \$pb_host map for subdomain-aware redirects."

    Assert-True ($nginxConfig -match '(?m)^\s*listen\s+80;') "Expected nginx to listen on port 80."

    # Named server blocks for each host
    Assert-True ($nginxConfig -match 'server_name\s+tools\.\$\{?ROOT_DOMAIN\}?\s+tools\.localtest\.me;') "Expected tools server block to derive its production domain from ROOT_DOMAIN."
    Assert-True ($nginxConfig -match 'server_name\s+omni\.tools\.\$\{?ROOT_DOMAIN\}?\s+omni\.tools\.localtest\.me;') "Expected omni.tools server block to derive its production domain from ROOT_DOMAIN."
    Assert-True ($nginxConfig -match 'server_name\s+it\.tools\.\$\{?ROOT_DOMAIN\}?\s+it\.tools\.localtest\.me;') "Expected it.tools server block to derive its production domain from ROOT_DOMAIN."
    Assert-True ($nginxConfig -match 'server_name\s+unfurl\.tools\.\$\{?ROOT_DOMAIN\}?\s+unfurl\.tools\.localtest\.me;') "Expected unfurl.tools server block to derive its production domain from ROOT_DOMAIN."
    Assert-True ($nginxConfig -match 'server_name\s+parsel\.tools\.\$\{?ROOT_DOMAIN\}?\s+parsel\.tools\.localtest\.me;') "Expected parsel.tools server block to derive its production domain from ROOT_DOMAIN."
    Assert-True ($nginxConfig -match 'server_name\s+stegg\.tools\.\$\{?ROOT_DOMAIN\}?\s+stegg\.tools\.localtest\.me;') "Expected stegg.tools server block to derive its production domain from ROOT_DOMAIN."
    Assert-True ($nginxConfig -match 'server_name\s+network\.tools\.\$\{?ROOT_DOMAIN\}?\s+network\.tools\.localtest\.me;') "Expected network.tools server block to derive its production domain from ROOT_DOMAIN."
    Assert-True ($nginxConfig -match 'server_name\s+pb\.tools\.\$\{?ROOT_DOMAIN\}?\s+pb\.tools\.localtest\.me;') "Expected pb.tools server block to derive its production domain from ROOT_DOMAIN."

    # Landing page served from filesystem on the tools host
    Assert-True ($nginxConfig -match '(?m)^\s*root\s+/usr/share/nginx/html;') "Expected nginx root to serve the landing page."
    Assert-True ($nginxConfig -match '(?m)^\s*index\s+index\.html;') "Expected nginx to serve index.html."

    # Legacy redirects on tools host forward to the correct subdomains using $redirect_scheme
    Assert-True ($nginxConfig -match '(?ms)location\s+/omni/\s*\{.*return\s+301\s+\$redirect_scheme://\$omni_host/;') "Expected legacy /omni/ redirect to \$omni_host subdomain using \$redirect_scheme."
    Assert-True ($nginxConfig -match '(?ms)location\s+/it-tools/\s*\{.*return\s+301\s+\$redirect_scheme://\$it_host/;') "Expected legacy /it-tools/ redirect to \$it_host subdomain using \$redirect_scheme."
    Assert-True ($nginxConfig -match '(?ms)location\s+/unfurl/\s*\{.*return\s+301\s+\$redirect_scheme://\$unfurl_host/;') "Expected legacy /unfurl/ redirect to \$unfurl_host subdomain using \$redirect_scheme."
    Assert-True ($nginxConfig -match '(?ms)location\s+/parsel/\s*\{.*return\s+301\s+\$redirect_scheme://\$parsel_host/;') "Expected legacy /parsel/ redirect to \$parsel_host subdomain using \$redirect_scheme."
    Assert-True ($nginxConfig -match '(?ms)location\s+/stegg/\s*\{.*return\s+301\s+\$redirect_scheme://\$stegg_host/;') "Expected legacy /stegg/ redirect to \$stegg_host subdomain using \$redirect_scheme."
    Assert-True ($nginxConfig -match '(?ms)location\s+/network/\s*\{.*return\s+301\s+\$redirect_scheme://\$network_host/;') "Expected legacy /network/ redirect to \$network_host subdomain using \$redirect_scheme."
    Assert-True ($nginxConfig -match '(?ms)location\s+/pb/\s*\{.*return\s+301\s+\$redirect_scheme://\$pb_host/;') "Expected legacy /pb/ redirect to \$pb_host subdomain using \$redirect_scheme."

    # CyberChef remains path-based on the tools host
    Assert-True ($nginxConfig -match '(?ms)location\s+/cyberchef/\s*\{.*proxy_pass\s+http://cyberchef:8080/;') "Expected CyberChef proxy block at /cyberchef/ targeting http://cyberchef:8080/."

    # Dedicated subdomain servers proxy the tools at /
    Assert-True ($nginxConfig -match 'proxy_pass\s+http://unfurl:5000/;') "Expected proxy_pass to http://unfurl:5000/ in the unfurl.tools server block."
    Assert-True ($nginxConfig -match 'proxy_pass\s+http://omni-tools:80/;') "Expected proxy_pass to http://omni-tools:80/ in the omni.tools server block."
    Assert-True ($nginxConfig -match 'proxy_pass\s+http://it-tools:80/;') "Expected proxy_pass to http://it-tools:80/ in the it.tools server block."
    Assert-True ($nginxConfig -match 'proxy_pass\s+http://parsel:\d+/;') "Expected proxy_pass to http://parsel:<port>/ in the parsel.tools server block."
    Assert-True ($nginxConfig -match 'proxy_pass\s+http://stegg:\d+/;') "Expected proxy_pass to http://stegg:<port>/ in the stegg.tools server block."
    Assert-True ($nginxConfig -match 'proxy_pass\s+http://network:3000/;') "Expected proxy_pass to http://network:3000/ in the network.tools server block."
    Assert-True ($nginxConfig -match 'proxy_pass\s+http://pb:8080/;') "Expected proxy_pass to http://pb:8080/ in the pb.tools server block."
    Assert-True ($nginxConfig -match '(?m)^\s*client_max_body_size\s+100m;') "Expected pb.tools server block to raise client_max_body_size for uploads."

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
        '-e', 'ROOT_DOMAIN=example.com',
        '--add-host', 'omni-tools:127.0.0.1',
        '--add-host', 'cyberchef:127.0.0.1',
        '--add-host', 'it-tools:127.0.0.1',
        '--add-host', 'parsel:127.0.0.1',
        '--add-host', 'stegg:127.0.0.1',
        '--add-host', 'network:127.0.0.1',
        '--add-host', 'pb:127.0.0.1',
        '--add-host', 'unfurl:127.0.0.1',
        '-v', "${repoRootForDocker}/landing/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro",
        'nginx:alpine',
        'sh', '-c', 'envsubst ''$ROOT_DOMAIN'' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf && nginx -t'
    )
    $null = docker @dockerArgs
    Assert-True ($LASTEXITCODE -eq 0) "Expected nginx -t to accept landing/nginx.conf.template."
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
        @{ Label = 'IT Tools'; Href = '/it-tools/'; Description = 'Developer utilities: tokens, hashes, formatters' },
        @{ Label = 'Parsel'; Href = '/parsel/'; Description = 'Parse and inspect structured data quickly' },
        @{ Label = 'Stegg'; Href = '/stegg/'; Description = 'Steganography workflows and payload inspection' },
        @{ Label = 'Network'; Href = '/network/'; Description = 'Network utilities and troubleshooting helpers' },
        @{ Label = 'PB'; Href = '/pb/'; Description = 'Paste and upload larger files in a dedicated subdomain' },
        @{ Label = 'Unfurl'; Href = '/unfurl/'; Description = 'URL decoding, parsing, and graph visualization' }
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
        'Copy-Item .env.example .env',
        'cp .env.example .env',
        'docker compose -f docker-compose.yml -f docker-compose.local.yml up -d',
        'http://tools.localtest.me:8080/',
        'http://omni.tools.localtest.me:8080/',
        'http://it.tools.localtest.me:8080/',
        'http://parsel.tools.localtest.me:8080/',
        'http://stegg.tools.localtest.me:8080/',
        'http://network.tools.localtest.me:8080/',
        'http://pb.tools.localtest.me:8080/',
        'http://unfurl.tools.localtest.me:8080/',
        'http://tools.localtest.me:8080/cyberchef/',
        'ROOT_DOMAIN',
        'toolkit-landing',
        'docker compose -f docker-compose.yml -f docker-compose.local.yml build parsel stegg unfurl',
        'docker compose -f docker-compose.yml -f docker-compose.local.yml build unfurl',
        'git clone https://github.com/elder-plinius/P4RS3LT0NGV3.git .',
        '730ce238a81357edcb07bfff91d0159de2556180',
        'git clone https://github.com/elder-plinius/ST3GG.git .',
        '7db09389507f90025e728a9516e155ebcf8dbeaf',
        'git clone https://github.com/RyanDFIR/unfurl /unfurl',
        '2d2dac375433d2a7fbeede2d25c5f19b68d4d244',
        '.\tests\verify-toolkit.ps1 scaffold',
        'bash ./tests/verify-toolkit.sh scaffold',
        'docker compose config',
        'docker ps',
        'docker network inspect nginx-proxy',
        'Invoke-WebRequest http://tools.localtest.me:8080/',
        'Invoke-WebRequest http://parsel.tools.localtest.me:8080/',
        'Invoke-WebRequest http://unfurl.tools.localtest.me:8080/',
        'curl -I http://tools.localtest.me:8080/',
        'curl -I http://parsel.tools.localtest.me:8080/',
        'curl -I http://unfurl.tools.localtest.me:8080/'
    )) {
        Assert-True ($readme -match [regex]::Escape($snippet)) "Expected README to mention '$snippet'."
    }

    Assert-True ($readme -notmatch 'n8-g\.com') "Expected README to stop hard-coding n8-g.com."
}

function Test-Runtime {
    # Landing page on the tools host
    $landingHtml = (curl.exe -s http://tools.localtest.me:8080/) -join "`n"
    Assert-True ($landingHtml -match '<title>\s*Tools\s*</title>') "Expected tools.localtest.me:8080/ to serve the landing page."

    # CyberChef remains path-based on the tools host
    $cyberchefHtml = (curl.exe -s http://tools.localtest.me:8080/cyberchef/) -join "`n"
    Assert-True ($cyberchefHtml -match '(?i)cyberchef') "Expected tools.localtest.me:8080/cyberchef/ to return CyberChef content."

    foreach ($tool in @(
        @{ Name = 'Omni Tools'; Host = 'omni.tools.localtest.me'; Path = '/'; Expect = '(?i)<html'; RedirectPath = '/omni/'; RedirectHost = 'omni.tools.localtest.me' },
        @{ Name = 'IT Tools'; Host = 'it.tools.localtest.me'; Path = '/'; Expect = '(?i)<html'; RedirectPath = '/it-tools/'; RedirectHost = 'it.tools.localtest.me' },
        @{ Name = 'Parsel'; Host = 'parsel.tools.localtest.me'; Path = '/'; Expect = '(?i)<html'; RedirectPath = '/parsel/'; RedirectHost = 'parsel.tools.localtest.me' },
        @{ Name = 'Stegg'; Host = 'stegg.tools.localtest.me'; Path = '/'; Expect = '(?i)<html'; RedirectPath = '/stegg/'; RedirectHost = 'stegg.tools.localtest.me' },
        @{ Name = 'Network'; Host = 'network.tools.localtest.me'; Path = '/'; Expect = '(?i)<html'; RedirectPath = '/network/'; RedirectHost = 'network.tools.localtest.me' },
        @{ Name = 'PB'; Host = 'pb.tools.localtest.me'; Path = '/'; Expect = '(?i)<html'; RedirectPath = '/pb/'; RedirectHost = 'pb.tools.localtest.me' },
        @{ Name = 'Unfurl'; Host = 'unfurl.tools.localtest.me'; Path = '/'; Expect = '(?i)<title>\s*unfurl\s*</title>'; RedirectPath = '/unfurl/'; RedirectHost = 'unfurl.tools.localtest.me' }
    )) {
        $html = (curl.exe -s ("http://{0}:8080{1}" -f $tool.Host, $tool.Path)) -join "`n"
        Assert-True ((-not [string]::IsNullOrWhiteSpace($html)) -and ($html -match $tool.Expect)) "Expected $($tool.Host):8080/ to return the $($tool.Name) app."

        $redirectCode = (curl.exe -s -o 'NUL' -w '%{http_code}' ("http://tools.localtest.me:8080{0}" -f $tool.RedirectPath)) -join ''
        Assert-True ($redirectCode -eq '301') "Expected tools.localtest.me:8080$($tool.RedirectPath) to return 301 redirect to the $($tool.Name) subdomain."

        $redirectHeaders = (curl.exe -s -I ("http://tools.localtest.me:8080{0}" -f $tool.RedirectPath)) -join "`n"
        Assert-True ($redirectHeaders -match ('(?i)location:\s*http://{0}:8080/' -f [regex]::Escape($tool.RedirectHost))) "Expected $($tool.RedirectPath) redirect Location to point to $($tool.RedirectHost):8080/."
    }
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
