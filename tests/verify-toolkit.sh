#!/usr/bin/env bash

set -euo pipefail

suite="${1:-scaffold}"
case "$suite" in
    scaffold|compose|proxy|landing|docs|runtime) ;;
    *)
        printf 'Expected suite to be one of: scaffold, compose, proxy, landing, docs, runtime.\n' >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
export TZ="${TZ:-America/New_York}"

find_python() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
    elif command -v python >/dev/null 2>&1; then
        command -v python
    else
        return 1
    fi
}

PYTHON_BIN="$(find_python)" || {
    printf 'Expected python3 or python to be available.\n' >&2
    exit 1
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

repo_path() {
    printf '%s/%s' "$REPO_ROOT" "$1"
}

compose_config_json() {
    local compose_args=()
    local file
    for file in "$@"; do
        compose_args+=(-f "$(repo_path "$file")")
    done

    (
        cd "$REPO_ROOT"
        docker compose "${compose_args[@]}" config --format json
    )
}

docker_host_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s' "$1"
    fi
}

assert_required_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Expected command '$1' to be available."
}

test_scaffold() {
    local required_files=(
        ".gitignore"
        ".env.example"
        "docker-compose.yml"
        "landing/index.html"
        "landing/nginx.conf.template"
        "parsel/Dockerfile"
        "stegg/Dockerfile"
        "unfurl/Dockerfile"
        "unfurl/unfurl.ini"
        "README.md"
        "tests/verify-toolkit.ps1"
        "tests/verify-toolkit.sh"
    )
    local relative_path

    for relative_path in "${required_files[@]}"; do
        [[ -e "$(repo_path "$relative_path")" ]] || fail "Expected required file '$relative_path' to exist."
    done

    "$PYTHON_BIN" - "$(repo_path ".gitignore")" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    entries = handle.read().splitlines()

if ".env" not in entries:
    raise SystemExit("Expected .gitignore to ignore '.env'.")
PY
}

test_compose() {
    assert_required_command docker
    [[ -e "$(repo_path "docker-compose.local.yml")" ]] || fail "Expected local override file 'docker-compose.local.yml' to exist."

    local tmp_dir
    tmp_dir="$REPO_ROOT/.verify-toolkit-compose.$$"
    mkdir -p "$tmp_dir"
    trap 'rm -rf "$tmp_dir"' RETURN

    compose_config_json "docker-compose.yml" > "$tmp_dir/base.json"
    compose_config_json "docker-compose.yml" "docker-compose.local.yml" > "$tmp_dir/local.json"

    "$PYTHON_BIN" - "$tmp_dir/base.json" "$tmp_dir/local.json" "$(repo_path "unfurl/Dockerfile")" <<'PY'
import json
import sys

base_path, local_path, unfurl_dockerfile_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(base_path, encoding="utf-8") as handle:
    base_config = json.load(handle)

with open(local_path, encoding="utf-8") as handle:
    local_config = json.load(handle)


def assert_true(condition, message):
    if not condition:
        raise SystemExit(message)


base_services = base_config["services"]
for service_name in ("toolkit-landing", "omni-tools", "cyberchef", "it-tools", "parsel", "stegg", "network", "pb", "unfurl"):
    service = base_services.get(service_name)
    assert_true(service is not None, f"Expected service '{service_name}' in docker-compose.yml.")
    assert_true(service.get("restart") == "unless-stopped", f"Expected '{service_name}' to use restart: unless-stopped.")
    assert_true(not service.get("ports"), f"Expected '{service_name}' to have no host ports in docker-compose.yml.")

assert_true(base_services["toolkit-landing"].get("image") == "nginx:alpine", "Expected toolkit-landing to use nginx:alpine.")
assert_true(str(base_services["toolkit-landing"].get("environment", {}).get("ROOT_DOMAIN", "")).strip() != "", "Expected toolkit-landing to receive ROOT_DOMAIN from the environment.")
assert_true(base_services["cyberchef"].get("image") == "ghcr.io/gchq/cyberchef:latest", "Expected cyberchef to use the official ghcr.io/gchq/cyberchef:latest image.")
assert_true(not base_services["it-tools"].get("environment", {}).get("BASE_URL"), "Expected it-tools to have no BASE_URL set (it now runs at /).")
assert_true(str(base_services["unfurl"].get("build", {}).get("context", "")).replace("\\\\", "/").endswith("/unfurl"), "Expected unfurl to build from the local unfurl directory.")
assert_true(base_services["unfurl"].get("build", {}).get("dockerfile") == "Dockerfile", "Expected unfurl to use the upstream Dockerfile.")

toolkit_networks = sorted(base_services["toolkit-landing"]["networks"].keys())
assert_true(",".join(toolkit_networks) == "nginx-proxy,toolkit-internal", "Expected toolkit-landing on both networks.")

for service_name in ("omni-tools", "cyberchef", "it-tools", "parsel", "stegg", "network", "pb", "unfurl"):
    service_networks = sorted(base_services[service_name]["networks"].keys())
    assert_true(",".join(service_networks) == "toolkit-internal", f"Expected '{service_name}' on toolkit-internal only.")

assert_true(base_config["networks"]["nginx-proxy"].get("external") is True, "Expected nginx-proxy network to be external.")
assert_true(base_config["networks"]["toolkit-internal"].get("driver") == "bridge", "Expected toolkit-internal network to use the bridge driver.")

toolkit_volumes = base_services["toolkit-landing"].get("volumes", [])
index_mount = next((volume for volume in toolkit_volumes if volume.get("target") == "/usr/share/nginx/html/index.html"), None)
template_mount = next((volume for volume in toolkit_volumes if volume.get("target") == "/etc/nginx/templates/default.conf.template"), None)
nginx_mount = next((volume for volume in toolkit_volumes if volume.get("target") == "/etc/nginx/conf.d/default.conf"), None)
assert_true(index_mount is not None and index_mount.get("read_only"), "Expected toolkit-landing to mount landing/index.html read-only.")
assert_true(template_mount is not None and template_mount.get("read_only"), "Expected toolkit-landing to mount an nginx template read-only.")
assert_true(nginx_mount is None, "Expected toolkit-landing to stop mounting a static landing/nginx.conf into conf.d/default.conf.")
unfurl_mount = next((volume for volume in base_services["unfurl"].get("volumes", []) if volume.get("target") == "/unfurl/unfurl.ini"), None)
assert_true(unfurl_mount is not None and unfurl_mount.get("read_only"), "Expected unfurl to mount unfurl/unfurl.ini read-only.")
pb_mount = next((volume for volume in base_services["pb"].get("volumes", []) if volume.get("target") == "/app/microbin_data"), None)
assert_true(pb_mount is not None, "Expected pb to mount persistent storage at /app/microbin_data.")
assert_true(str(base_services["network"].get("environment", {}).get("PORT", "")) == "3000", "Expected network to expose its upstream app on port 3000.")
assert_true(str(base_services["pb"].get("environment", {}).get("MICROBIN_PORT", "")) == "8080", "Expected pb to expose MicroBin on port 8080.")
with open(unfurl_dockerfile_path, encoding="utf-8") as handle:
    unfurl_dockerfile = handle.read()
assert_true("git clone https://github.com/RyanDFIR/unfurl /unfurl" in unfurl_dockerfile, "Expected unfurl Dockerfile to clone the RyanDFIR/unfurl repository during build.")
assert_true("git checkout 2d2dac375433d2a7fbeede2d25c5f19b68d4d244" in unfurl_dockerfile, "Expected unfurl Dockerfile to pin the upstream checkout to the planned commit.")

local_services = local_config["services"]
toolkit_ports = local_services["toolkit-landing"].get("ports", [])
localhost_port = next(
    (
        port
        for port in toolkit_ports
        if str(port.get("published")) == "8080" and int(port.get("target")) == 80
    ),
    None,
)
assert_true(localhost_port is not None, "Expected local override to expose toolkit-landing on 8080.")
assert_true(local_config["networks"]["nginx-proxy"].get("external") is not True, "Expected local override to avoid requiring a pre-existing external nginx-proxy network.")

for service_name in ("omni-tools", "cyberchef", "it-tools", "parsel", "stegg", "network", "pb", "unfurl"):
    assert_true(not local_services[service_name].get("ports"), f"Expected '{service_name}' to remain unexposed in local override.")
PY
}

test_proxy() {
    assert_required_command docker

    local nginx_config_path
    nginx_config_path="$(repo_path "landing/nginx.conf.template")"

    "$PYTHON_BIN" - "$nginx_config_path" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    nginx_config = handle.read()


def assert_true(condition, message):
    if not condition:
        raise SystemExit(message)


patterns = (
    (r'(?ms)map \$http_x_forwarded_proto \$redirect_scheme \{.*default \$http_x_forwarded_proto;.*""\s+\$scheme;.*\}', "Expected nginx config to map forwarded HTTPS to a redirect-safe scheme."),
    (r'ROOT_DOMAIN', "Expected nginx template to use ROOT_DOMAIN instead of a hard-coded production domain."),
    (r'n8-g\.com', None),
    (r'map \$http_host \$omni_host', r"Expected nginx config to define an \$omni_host map for subdomain-aware redirects."),
    (r'map \$http_host \$it_host', r"Expected nginx config to define an \$it_host map for subdomain-aware redirects."),
    (r'map \$http_host \$unfurl_host', r"Expected nginx config to define an \$unfurl_host map for subdomain-aware redirects."),
    (r'map \$http_host \$parsel_host', r"Expected nginx config to define an \$parsel_host map for subdomain-aware redirects."),
    (r'map \$http_host \$stegg_host', r"Expected nginx config to define an \$stegg_host map for subdomain-aware redirects."),
    (r'map \$http_host \$network_host', r"Expected nginx config to define an \$network_host map for subdomain-aware redirects."),
    (r'map \$http_host \$pb_host', r"Expected nginx config to define an \$pb_host map for subdomain-aware redirects."),
    (r'(?m)^\s*listen\s+80;', "Expected nginx to listen on port 80."),
    (r'server_name\s+tools\.\$\{?ROOT_DOMAIN\}?\s+tools\.localtest\.me;', "Expected tools server block to derive its production domain from ROOT_DOMAIN."),
    (r'server_name\s+omni\.tools\.\$\{?ROOT_DOMAIN\}?\s+omni\.tools\.localtest\.me;', "Expected omni.tools server block to derive its production domain from ROOT_DOMAIN."),
    (r'server_name\s+it\.tools\.\$\{?ROOT_DOMAIN\}?\s+it\.tools\.localtest\.me;', "Expected it.tools server block to derive its production domain from ROOT_DOMAIN."),
    (r'server_name\s+unfurl\.tools\.\$\{?ROOT_DOMAIN\}?\s+unfurl\.tools\.localtest\.me;', "Expected unfurl.tools server block to derive its production domain from ROOT_DOMAIN."),
    (r'server_name\s+parsel\.tools\.\$\{?ROOT_DOMAIN\}?\s+parsel\.tools\.localtest\.me;', "Expected parsel.tools server block to derive its production domain from ROOT_DOMAIN."),
    (r'server_name\s+stegg\.tools\.\$\{?ROOT_DOMAIN\}?\s+stegg\.tools\.localtest\.me;', "Expected stegg.tools server block to derive its production domain from ROOT_DOMAIN."),
    (r'server_name\s+network\.tools\.\$\{?ROOT_DOMAIN\}?\s+network\.tools\.localtest\.me;', "Expected network.tools server block to derive its production domain from ROOT_DOMAIN."),
    (r'server_name\s+pb\.tools\.\$\{?ROOT_DOMAIN\}?\s+pb\.tools\.localtest\.me;', "Expected pb.tools server block to derive its production domain from ROOT_DOMAIN."),
    (r'(?m)^\s*root\s+/usr/share/nginx/html;', "Expected nginx root to serve the landing page."),
    (r'(?m)^\s*index\s+index\.html;', "Expected nginx to serve index.html."),
    (r'(?ms)location\s+/omni/\s*\{.*return\s+301\s+\$redirect_scheme://\$omni_host/;', r"Expected legacy /omni/ redirect to \$omni_host subdomain using \$redirect_scheme."),
    (r'(?ms)location\s+/it-tools/\s*\{.*return\s+301\s+\$redirect_scheme://\$it_host/;', r"Expected legacy /it-tools/ redirect to \$it_host subdomain using \$redirect_scheme."),
    (r'(?ms)location\s+/unfurl/\s*\{.*return\s+301\s+\$redirect_scheme://\$unfurl_host/;', r"Expected legacy /unfurl/ redirect to \$unfurl_host subdomain using \$redirect_scheme."),
    (r'(?ms)location\s+/parsel/\s*\{.*return\s+301\s+\$redirect_scheme://\$parsel_host/;', r"Expected legacy /parsel/ redirect to \$parsel_host subdomain using \$redirect_scheme."),
    (r'(?ms)location\s+/stegg/\s*\{.*return\s+301\s+\$redirect_scheme://\$stegg_host/;', r"Expected legacy /stegg/ redirect to \$stegg_host subdomain using \$redirect_scheme."),
    (r'(?ms)location\s+/network/\s*\{.*return\s+301\s+\$redirect_scheme://\$network_host/;', r"Expected legacy /network/ redirect to \$network_host subdomain using \$redirect_scheme."),
    (r'(?ms)location\s+/pb/\s*\{.*return\s+301\s+\$redirect_scheme://\$pb_host/;', r"Expected legacy /pb/ redirect to \$pb_host subdomain using \$redirect_scheme."),
    (r'(?ms)location\s+/cyberchef/\s*\{.*proxy_pass\s+http://cyberchef:8080/;', "Expected CyberChef proxy block at /cyberchef/ targeting http://cyberchef:8080/."),
    (r'proxy_pass\s+http://unfurl:5000/;', "Expected proxy_pass to http://unfurl:5000/ in the unfurl.tools server block."),
    (r'proxy_pass\s+http://omni-tools:80/;', "Expected proxy_pass to http://omni-tools:80/ in the omni.tools server block."),
    (r'proxy_pass\s+http://it-tools:80/;', "Expected proxy_pass to http://it-tools:80/ in the it.tools server block."),
    (r'proxy_pass\s+http://parsel:\d+/;', "Expected proxy_pass to http://parsel:<port>/ in the parsel.tools server block."),
    (r'proxy_pass\s+http://stegg:\d+/;', "Expected proxy_pass to http://stegg:<port>/ in the stegg.tools server block."),
    (r'proxy_pass\s+http://network:3000/;', "Expected proxy_pass to http://network:3000/ in the network.tools server block."),
    (r'proxy_pass\s+http://pb:8080/;', "Expected proxy_pass to http://pb:8080/ in the pb.tools server block."),
    (r'(?m)^\s*client_max_body_size\s+100m;', "Expected pb.tools server block to raise client_max_body_size for uploads."),
    (r'proxy_set_header\s+Host\s+\$host;', r"Expected nginx config to include proxy_set_header directive 'proxy_set_header\s+Host\s+\$host;'."),
    (r'proxy_set_header\s+X-Real-IP\s+\$remote_addr;', r"Expected nginx config to include proxy_set_header directive 'proxy_set_header\s+X-Real-IP\s+\$remote_addr;'."),
    (r'proxy_set_header\s+X-Forwarded-For\s+\$proxy_add_x_forwarded_for;', r"Expected nginx config to include proxy_set_header directive 'proxy_set_header\s+X-Forwarded-For\s+\$proxy_add_x_forwarded_for;'."),
    (r'proxy_set_header\s+X-Forwarded-Proto\s+\$scheme;', r"Expected nginx config to include proxy_set_header directive 'proxy_set_header\s+X-Forwarded-Proto\s+\$scheme;'."),
    (r'(?m)^\s*access_log\s+/dev/stdout;', "Expected nginx access logs on stdout."),
    (r'(?m)^\s*error_log\s+/dev/stderr\s+warn;', "Expected nginx error logs on stderr."),
)

for pattern, message in patterns:
    if message is None:
        assert_true(re.search(pattern, nginx_config) is None, f"Expected nginx template to avoid hard-coded '{pattern}' references.")
    else:
        assert_true(re.search(pattern, nginx_config) is not None, message)
PY

    docker run --rm \
        -e ROOT_DOMAIN=example.com \
        --add-host omni-tools:127.0.0.1 \
        --add-host cyberchef:127.0.0.1 \
        --add-host it-tools:127.0.0.1 \
        --add-host parsel:127.0.0.1 \
        --add-host stegg:127.0.0.1 \
        --add-host network:127.0.0.1 \
        --add-host pb:127.0.0.1 \
        --add-host unfurl:127.0.0.1 \
        -v "$(docker_host_path "$REPO_ROOT")/landing/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro" \
        nginx:alpine \
        sh -c 'envsubst '\''$ROOT_DOMAIN'\'' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf && nginx -t'
}

test_landing() {
    local index_path
    index_path="$(repo_path "landing/index.html")"

    "$PYTHON_BIN" - "$index_path" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    index_html = handle.read()


def assert_true(condition, message):
    if not condition:
        raise SystemExit(message)


assert_true(re.search(r'<title>\s*Tools\s*</title>', index_html) is not None, "Expected landing page title to be 'Tools'.")
assert_true("<style>" in index_html, "Expected landing page to include inline CSS.")
assert_true(re.search(r'<script\b', index_html) is None, "Expected landing page to avoid JavaScript frameworks.")
assert_true(re.search(r'https?://', index_html) is None, "Expected landing page to avoid external CDN dependencies.")

for link in (
    {"label": "Omni Tools", "href": "/omni/", "description": "General-purpose browser tools"},
    {"label": "CyberChef", "href": "/cyberchef/", "description": "Encoding, decoding, encryption, data analysis"},
    {"label": "IT Tools", "href": "/it-tools/", "description": "Developer utilities: tokens, hashes, formatters"},
    {"label": "Parsel", "href": "/parsel/", "description": "Parse and inspect structured data quickly"},
    {"label": "Stegg", "href": "/stegg/", "description": "Steganography workflows and payload inspection"},
    {"label": "Network", "href": "/network/", "description": "Network utilities and troubleshooting helpers"},
    {"label": "PB", "href": "/pb/", "description": "Paste and upload larger files in a dedicated subdomain"},
    {"label": "Unfurl", "href": "/unfurl/", "description": "URL decoding, parsing, and graph visualization"},
):
    pattern = (
        r'(?ms)<a[^>]*href="' + re.escape(link["href"]) + r'"[^>]*target="_blank"[^>]*>.*?'
        + re.escape(link["label"]) + r'.*?' + re.escape(link["description"]) + r'.*?</a>'
    )
    assert_true(re.search(pattern, index_html) is not None, f"Expected landing page card for '{link['label']}' linking to '{link['href']}'.")
PY
}

test_docs() {
    local readme_path
    readme_path="$(repo_path "README.md")"

    "$PYTHON_BIN" - "$readme_path" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    readme = handle.read()


def assert_true(condition, message):
    if not condition:
        raise SystemExit(message)


for section in (
    "## Repository Structure",
    "## Local Development",
    "## Production Notes",
    "## Verification",
):
    assert_true(re.search(re.escape(section), readme) is not None, f"Expected README section '{section}'.")

for snippet in (
    "Copy-Item .env.example .env",
    "cp .env.example .env",
    "docker compose -f docker-compose.yml -f docker-compose.local.yml up -d",
    "http://tools.localtest.me:8080/",
    "http://omni.tools.localtest.me:8080/",
    "http://it.tools.localtest.me:8080/",
    "http://parsel.tools.localtest.me:8080/",
    "http://stegg.tools.localtest.me:8080/",
    "http://network.tools.localtest.me:8080/",
    "http://pb.tools.localtest.me:8080/",
    "http://unfurl.tools.localtest.me:8080/",
    "http://tools.localtest.me:8080/cyberchef/",
    "ROOT_DOMAIN",
    "toolkit-landing",
    "docker compose -f docker-compose.yml -f docker-compose.local.yml build unfurl",
    "git clone https://github.com/RyanDFIR/unfurl /unfurl",
    "2d2dac375433d2a7fbeede2d25c5f19b68d4d244",
    r".\tests\verify-toolkit.ps1 scaffold",
    "bash ./tests/verify-toolkit.sh scaffold",
    "docker compose config",
    "docker ps",
    "docker network inspect nginx-proxy",
    "Invoke-WebRequest http://tools.localtest.me:8080/",
    "Invoke-WebRequest http://parsel.tools.localtest.me:8080/",
    "Invoke-WebRequest http://unfurl.tools.localtest.me:8080/",
    "curl -I http://tools.localtest.me:8080/",
    "curl -I http://parsel.tools.localtest.me:8080/",
    "curl -I http://unfurl.tools.localtest.me:8080/",
):
    assert_true(re.search(re.escape(snippet), readme) is not None, f"Expected README to mention '{snippet}'.")
PY

    if grep -Eqi 'n8-g\.com' "$readme_path"; then
        fail "Expected README to stop hard-coding n8-g.com."
    fi
}

test_runtime() {
    local curl_cmd="curl"
    local curl_null_device="/dev/null"
    if command -v curl.exe >/dev/null 2>&1; then
        curl_cmd="curl.exe"
        curl_null_device="NUL"
    else
        assert_required_command curl
    fi

    local landing_html
    landing_html="$("$curl_cmd" -fsS http://tools.localtest.me:8080/)"
    grep -Eiq '<title>[[:space:]]*Tools[[:space:]]*</title>' <<<"$landing_html" || fail "Expected tools.localtest.me:8080/ to serve the landing page."

    local cyberchef_html
    cyberchef_html="$("$curl_cmd" -fsS http://tools.localtest.me:8080/cyberchef/)"
    grep -iq 'cyberchef' <<<"$cyberchef_html" || fail "Expected tools.localtest.me:8080/cyberchef/ to return CyberChef content."

    for entry in \
        "Omni Tools|omni.tools.localtest.me|/omni/|<html" \
        "IT Tools|it.tools.localtest.me|/it-tools/|<html" \
        "Parsel|parsel.tools.localtest.me|/parsel/|<html" \
        "Stegg|stegg.tools.localtest.me|/stegg/|<html" \
        "Network|network.tools.localtest.me|/network/|<html" \
        "PB|pb.tools.localtest.me|/pb/|<html" \
        "Unfurl|unfurl.tools.localtest.me|/unfurl/|<title>[[:space:]]*unfurl[[:space:]]*</title>"
    do
        IFS='|' read -r name host redirect_path html_pattern <<<"$entry"
        local html
        html="$("$curl_cmd" -fsS "http://${host}:8080/")"
        [[ -n "${html//[[:space:]]/}" ]] && grep -Eiq "$html_pattern" <<<"$html" || fail "Expected ${host}:8080/ to return the ${name} app."

        local redirect_code
        redirect_code="$("$curl_cmd" -s -o "$curl_null_device" -w '%{http_code}' "http://tools.localtest.me:8080${redirect_path}")"
        [[ "$redirect_code" == "301" ]] || fail "Expected tools.localtest.me:8080${redirect_path} to return 301 redirect to the ${name} subdomain."

        local redirect_headers
        redirect_headers="$("$curl_cmd" -sI "http://tools.localtest.me:8080${redirect_path}")"
        grep -Eiq "^location:[[:space:]]*http://${host}:8080/" <<<"$redirect_headers" || fail "Expected ${redirect_path} redirect Location to point to ${host}:8080/."
    done
}

case "$suite" in
    scaffold) test_scaffold ;;
    compose) test_compose ;;
    proxy) test_proxy ;;
    landing) test_landing ;;
    docs) test_docs ;;
    runtime) test_runtime ;;
esac

printf 'PASS: %s\n' "$suite"
