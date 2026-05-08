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
        "landing/nginx.conf"
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
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    compose_config_json "docker-compose.yml" > "$tmp_dir/base.json"
    compose_config_json "docker-compose.yml" "docker-compose.local.yml" > "$tmp_dir/local.json"

    "$PYTHON_BIN" - "$tmp_dir/base.json" "$tmp_dir/local.json" <<'PY'
import json
import sys

base_path, local_path = sys.argv[1], sys.argv[2]

with open(base_path, encoding="utf-8") as handle:
    base_config = json.load(handle)

with open(local_path, encoding="utf-8") as handle:
    local_config = json.load(handle)


def assert_true(condition, message):
    if not condition:
        raise SystemExit(message)


base_services = base_config["services"]
for service_name in ("toolkit-landing", "omni-tools", "cyberchef", "it-tools", "unfurl"):
    service = base_services.get(service_name)
    assert_true(service is not None, f"Expected service '{service_name}' in docker-compose.yml.")
    assert_true(service.get("restart") == "unless-stopped", f"Expected '{service_name}' to use restart: unless-stopped.")
    assert_true(not service.get("ports"), f"Expected '{service_name}' to have no host ports in docker-compose.yml.")

assert_true(base_services["toolkit-landing"].get("image") == "nginx:alpine", "Expected toolkit-landing to use nginx:alpine.")
assert_true(base_services["cyberchef"].get("image") == "ghcr.io/gchq/cyberchef:latest", "Expected cyberchef to use the official ghcr.io/gchq/cyberchef:latest image.")
assert_true(not base_services["it-tools"].get("environment", {}).get("BASE_URL"), "Expected it-tools to have no BASE_URL set (it now runs at /).")
assert_true(str(base_services["unfurl"].get("build", {}).get("context", "")).replace("\\\\", "/").endswith("/unfurl"), "Expected unfurl to build from the local unfurl directory.")
assert_true(base_services["unfurl"].get("build", {}).get("dockerfile") == "Dockerfile", "Expected unfurl to use the upstream Dockerfile.")

toolkit_networks = sorted(base_services["toolkit-landing"]["networks"].keys())
assert_true(",".join(toolkit_networks) == "nginx-proxy,toolkit-internal", "Expected toolkit-landing on both networks.")

for service_name in ("omni-tools", "cyberchef", "it-tools", "unfurl"):
    service_networks = sorted(base_services[service_name]["networks"].keys())
    assert_true(",".join(service_networks) == "toolkit-internal", f"Expected '{service_name}' on toolkit-internal only.")

assert_true(base_config["networks"]["nginx-proxy"].get("external") is True, "Expected nginx-proxy network to be external.")
assert_true(base_config["networks"]["toolkit-internal"].get("driver") == "bridge", "Expected toolkit-internal network to use the bridge driver.")

toolkit_volumes = base_services["toolkit-landing"].get("volumes", [])
index_mount = next((volume for volume in toolkit_volumes if volume.get("target") == "/usr/share/nginx/html/index.html"), None)
nginx_mount = next((volume for volume in toolkit_volumes if volume.get("target") == "/etc/nginx/conf.d/default.conf"), None)
assert_true(index_mount is not None and index_mount.get("read_only"), "Expected toolkit-landing to mount landing/index.html read-only.")
assert_true(nginx_mount is not None and nginx_mount.get("read_only"), "Expected toolkit-landing to mount landing/nginx.conf read-only.")
unfurl_mount = next((volume for volume in base_services["unfurl"].get("volumes", []) if volume.get("target") == "/unfurl/unfurl.ini"), None)
assert_true(unfurl_mount is not None and unfurl_mount.get("read_only"), "Expected unfurl to mount unfurl/unfurl.ini read-only.")
with open(repo_path("unfurl/Dockerfile"), encoding="utf-8") as handle:
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

for service_name in ("omni-tools", "cyberchef", "it-tools", "unfurl"):
    assert_true(not local_services[service_name].get("ports"), f"Expected '{service_name}' to remain unexposed in local override.")
PY
}

test_proxy() {
    assert_required_command docker

    local nginx_config_path
    nginx_config_path="$(repo_path "landing/nginx.conf")"

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
    (r'map \$http_host \$omni_host', r"Expected nginx config to define an \$omni_host map for subdomain-aware redirects."),
    (r'map \$http_host \$it_host', r"Expected nginx config to define an \$it_host map for subdomain-aware redirects."),
    (r'map \$http_host \$unfurl_host', r"Expected nginx config to define an \$unfurl_host map for subdomain-aware redirects."),
    (r'(?m)^\s*listen\s+80;', "Expected nginx to listen on port 80."),
    (r'server_name\s+tools\.n8-g\.com\s+tools\.localtest\.me;', "Expected tools server block with server_name tools.n8-g.com tools.localtest.me."),
    (r'server_name\s+omni\.tools\.n8-g\.com\s+omni\.tools\.localtest\.me;', "Expected omni.tools server block with server_name omni.tools.n8-g.com omni.tools.localtest.me."),
    (r'server_name\s+it\.tools\.n8-g\.com\s+it\.tools\.localtest\.me;', "Expected it.tools server block with server_name it.tools.n8-g.com it.tools.localtest.me."),
    (r'server_name\s+unfurl\.tools\.n8-g\.com\s+unfurl\.tools\.localtest\.me;', "Expected unfurl.tools server block with server_name unfurl.tools.n8-g.com unfurl.tools.localtest.me."),
    (r'(?m)^\s*root\s+/usr/share/nginx/html;', "Expected nginx root to serve the landing page."),
    (r'(?m)^\s*index\s+index\.html;', "Expected nginx to serve index.html."),
    (r'(?ms)location\s+/omni/\s*\{.*return\s+301\s+\$redirect_scheme://\$omni_host/;', r"Expected legacy /omni/ redirect to \$omni_host subdomain using \$redirect_scheme."),
    (r'(?ms)location\s+/it-tools/\s*\{.*return\s+301\s+\$redirect_scheme://\$it_host/;', r"Expected legacy /it-tools/ redirect to \$it_host subdomain using \$redirect_scheme."),
    (r'(?ms)location\s+/unfurl/\s*\{.*return\s+301\s+\$redirect_scheme://\$unfurl_host/;', r"Expected legacy /unfurl/ redirect to \$unfurl_host subdomain using \$redirect_scheme."),
    (r'(?ms)location\s+/cyberchef/\s*\{.*proxy_pass\s+http://cyberchef:8080/;', "Expected CyberChef proxy block at /cyberchef/ targeting http://cyberchef:8080/."),
    (r'proxy_pass\s+http://unfurl:5000/;', "Expected proxy_pass to http://unfurl:5000/ in the unfurl.tools server block."),
    (r'proxy_pass\s+http://omni-tools:80/;', "Expected proxy_pass to http://omni-tools:80/ in the omni.tools server block."),
    (r'proxy_pass\s+http://it-tools:80/;', "Expected proxy_pass to http://it-tools:80/ in the it.tools server block."),
    (r'proxy_set_header\s+Host\s+\$host;', r"Expected nginx config to include proxy_set_header directive 'proxy_set_header\s+Host\s+\$host;'."),
    (r'proxy_set_header\s+X-Real-IP\s+\$remote_addr;', r"Expected nginx config to include proxy_set_header directive 'proxy_set_header\s+X-Real-IP\s+\$remote_addr;'."),
    (r'proxy_set_header\s+X-Forwarded-For\s+\$proxy_add_x_forwarded_for;', r"Expected nginx config to include proxy_set_header directive 'proxy_set_header\s+X-Forwarded-For\s+\$proxy_add_x_forwarded_for;'."),
    (r'proxy_set_header\s+X-Forwarded-Proto\s+\$scheme;', r"Expected nginx config to include proxy_set_header directive 'proxy_set_header\s+X-Forwarded-Proto\s+\$scheme;'."),
    (r'(?m)^\s*access_log\s+/dev/stdout;', "Expected nginx access logs on stdout."),
    (r'(?m)^\s*error_log\s+/dev/stderr\s+warn;', "Expected nginx error logs on stderr."),
)

for pattern, message in patterns:
    assert_true(re.search(pattern, nginx_config) is not None, message)
PY

    docker run --rm \
        --add-host omni-tools:127.0.0.1 \
        --add-host cyberchef:127.0.0.1 \
        --add-host it-tools:127.0.0.1 \
        --add-host unfurl:127.0.0.1 \
        -v "$(docker_host_path "$REPO_ROOT")/landing/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        nginx:alpine \
        nginx -t
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
    "http://unfurl.tools.localtest.me:8080/",
    "http://tools.localtest.me:8080/cyberchef/",
    "tools.n8-g.com",
    "omni.tools.n8-g.com",
    "it.tools.n8-g.com",
    "unfurl.tools.n8-g.com",
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
    "Invoke-WebRequest http://unfurl.tools.localtest.me:8080/",
    "curl -I http://tools.localtest.me:8080/",
    "curl -I http://unfurl.tools.localtest.me:8080/",
):
    assert_true(re.search(re.escape(snippet), readme) is not None, f"Expected README to mention '{snippet}'.")
PY
}

test_runtime() {
    assert_required_command curl

    local landing_html
    landing_html="$(curl -fsS http://tools.localtest.me:8080/)"
    grep -Eiq '<title>[[:space:]]*Tools[[:space:]]*</title>' <<<"$landing_html" || fail "Expected tools.localtest.me:8080/ to serve the landing page."

    local cyberchef_html
    cyberchef_html="$(curl -fsS http://tools.localtest.me:8080/cyberchef/)"
    grep -iq 'cyberchef' <<<"$cyberchef_html" || fail "Expected tools.localtest.me:8080/cyberchef/ to return CyberChef content."

    local omni_html
    omni_html="$(curl -fsS http://omni.tools.localtest.me:8080/)"
    [[ -n "${omni_html//[[:space:]]/}" ]] && grep -iq '<html' <<<"$omni_html" || fail "Expected omni.tools.localtest.me:8080/ to return an HTML page."

    local it_html
    it_html="$(curl -fsS http://it.tools.localtest.me:8080/)"
    [[ -n "${it_html//[[:space:]]/}" ]] && grep -iq '<html' <<<"$it_html" || fail "Expected it.tools.localtest.me:8080/ to return an HTML page."

    local unfurl_html
    unfurl_html="$(curl -fsS http://unfurl.tools.localtest.me:8080/)"
    grep -Eiq '<title>[[:space:]]*unfurl[[:space:]]*</title>' <<<"$unfurl_html" || fail "Expected unfurl.tools.localtest.me:8080/ to return the Unfurl UI."

    local omni_redirect_code
    omni_redirect_code="$(curl -s -o /dev/null -w '%{http_code}' http://tools.localtest.me:8080/omni/)"
    [[ "$omni_redirect_code" == "301" ]] || fail "Expected tools.localtest.me:8080/omni/ to return 301 redirect to the omni subdomain."

    local omni_redirect_headers
    omni_redirect_headers="$(curl -sI http://tools.localtest.me:8080/omni/)"
    grep -Eiq '^location:[[:space:]]*http://omni\.tools\.localtest\.me:8080/' <<<"$omni_redirect_headers" || fail "Expected /omni/ redirect Location to point to omni.tools.localtest.me:8080/."

    local it_redirect_code
    it_redirect_code="$(curl -s -o /dev/null -w '%{http_code}' http://tools.localtest.me:8080/it-tools/)"
    [[ "$it_redirect_code" == "301" ]] || fail "Expected tools.localtest.me:8080/it-tools/ to return 301 redirect to the it subdomain."

    local it_redirect_headers
    it_redirect_headers="$(curl -sI http://tools.localtest.me:8080/it-tools/)"
    grep -Eiq '^location:[[:space:]]*http://it\.tools\.localtest\.me:8080/' <<<"$it_redirect_headers" || fail "Expected /it-tools/ redirect Location to point to it.tools.localtest.me:8080/."

    local unfurl_redirect_code
    unfurl_redirect_code="$(curl -s -o /dev/null -w '%{http_code}' http://tools.localtest.me:8080/unfurl/)"
    [[ "$unfurl_redirect_code" == "301" ]] || fail "Expected tools.localtest.me:8080/unfurl/ to return 301 redirect to the Unfurl subdomain."

    local unfurl_redirect_headers
    unfurl_redirect_headers="$(curl -sI http://tools.localtest.me:8080/unfurl/)"
    grep -Eiq '^location:[[:space:]]*http://unfurl\.tools\.localtest\.me:8080/' <<<"$unfurl_redirect_headers" || fail "Expected /unfurl/ redirect Location to point to unfurl.tools.localtest.me:8080/."
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
