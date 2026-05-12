# Conversion Toolkit - Requirements Document

## Overview

A self-hosted web toolkit served through `tools.${ROOT_DOMAIN}`. A custom
landing page acts as the hub and reverse-proxies only the shared subpath app
(`CyberChef`) while the rest of the tools are published on subdomains.

Production routing is driven by a `.env` root-domain value such as
`ROOT_DOMAIN=domain.com`. NPM forwards `tools.${ROOT_DOMAIN}` to
`toolkit-landing`, and `toolkit-landing` routes the request to the right
internal service or subdomain target. Local testing keeps using
`tools.localtest.me:8080` and matching subdomains.

TLS, certificate creation, and certificate renewal are handled manually in NPM
and are out of scope for this phase.

---

## Repository Structure

```text
toolkit/
├── docker-compose.yml
├── docker-compose.local.yml
├── .env                    # gitignored
├── .env.example            # committed, documents required vars
├── landing/
│   ├── index.html          # static landing page
│   └── nginx.conf.template # env-driven nginx template
├── parsel/
│   └── Dockerfile
├── stegg/
│   └── Dockerfile
├── unfurl/
│   └── unfurl.ini
└── README.md
```

---

## Networking

Two networks are used:

| Network | Type | Purpose |
| --- | --- | --- |
| `nginx-proxy` | external (pre-existing) | NPM -> `toolkit-landing` only |
| `toolkit-internal` | bridge, created by compose | `toolkit-landing` -> tool containers only |

- `toolkit-landing` is the only container on both networks
- Tool containers are on `toolkit-internal` only
- Tool containers are not reachable from NPM or any other container on `nginx-proxy`
- Local Compose should only expose `toolkit-landing` on port `8080`

```text
NPM (nginx-proxy) -> toolkit-landing (nginx-proxy + toolkit-internal)
                                |
                   +------------+------------+
                   v            v            v
               tool subdomains  CyberChef   shared routes
               (internal only)
```

NPM proxy host entry (one entry, configured manually after deploy):

| NPM Proxy Host | Forward Hostname | Forward Port |
| --- | --- | --- |
| `tools.${ROOT_DOMAIN}` | `toolkit-landing` | `80` |

---

## Routing Model

Shared subpath routing:

| URL path | App | Notes |
| --- | --- | --- |
| `/` | Landing page | Root hub |
| `/cyberchef/` | CyberChef | Shared subpath app |

Dedicated subdomain routing:

| Host | App | Notes |
| --- | --- | --- |
| `omni.tools.${ROOT_DOMAIN}` | Omni Tools | Subdomain only |
| `it.tools.${ROOT_DOMAIN}` | IT Tools | Subdomain only |
| `unfurl.tools.${ROOT_DOMAIN}` | Unfurl | Root-level upstream routes |
| `parsel.tools.${ROOT_DOMAIN}` | Parsel | Repo-local build |
| `stegg.tools.${ROOT_DOMAIN}` | Stegg | Repo-local build/static app |
| `network.tools.${ROOT_DOMAIN}` | Network | Published `lissy93/networking-toolbox` image |
| `pb.tools.${ROOT_DOMAIN}` | PB / MicroBin | Dedicated host preferred |

---

## Services

### 1. Landing + Proxy - `toolkit-landing`
- Image: `nginx:alpine`
- Purpose: serves `index.html` and routes requests to the tool containers
- Volumes:
  - `./landing/index.html:/usr/share/nginx/html/index.html:ro`
  - `./landing/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro`
- Networks: `nginx-proxy`, `toolkit-internal`
- No host port bindings in production
- `restart: unless-stopped`
- Receives `ROOT_DOMAIN` from the environment

### 2. Omni Tools - `omni-tools`
- Image: published container image
- Purpose: general-purpose browser tools
- Access: `omni.tools.${ROOT_DOMAIN}`
- Networks: `toolkit-internal` only
- No host port bindings

### 3. CyberChef - `cyberchef`
- Image: published container image
- Purpose: encoding, decoding, encryption, hashing, and format conversion
- Access: `/cyberchef/` on `tools.${ROOT_DOMAIN}`
- Networks: `toolkit-internal` only
- No host port bindings

### 4. IT Tools - `it-tools`
- Image: published container image
- Purpose: developer utilities
- Access: `it.tools.${ROOT_DOMAIN}`
- Networks: `toolkit-internal` only
- No host port bindings

### 5. Unfurl - `unfurl`
- Image source: repo-local Docker build
- Purpose: URL analysis and expansion
- Access: `unfurl.tools.${ROOT_DOMAIN}`
- Notes: keep the pinned upstream commit in the Docker build

### 6. Parsel - `parsel`
- Image source: repo-local Docker build
- Purpose: subdomain-served tool package
- Access: `parsel.tools.${ROOT_DOMAIN}`
- Notes: keep it on its own host instead of a shared subpath

### 7. Stegg - `stegg`
- Image source: repo-local Docker build or static app container
- Purpose: subdomain-served tool package
- Access: `stegg.tools.${ROOT_DOMAIN}`
- Notes: keep it on its own host instead of a shared subpath

### 8. Network - `network`
- Image source: published `lissy93/networking-toolbox`
- Purpose: networking utilities
- Access: `network.tools.${ROOT_DOMAIN}`
- Notes:
  - subdomain only
  - do not treat it as a shared subpath app
  - document any upstream port or path expectations before finalizing proxy rules

### 9. PB / MicroBin - `pb`
- Image source: published MicroBin image
- Purpose: paste bin / file drop service
- Access: `pb.tools.${ROOT_DOMAIN}`
- Notes:
  - dedicated subdomain preferred
  - requires persistent volume storage
  - requires admin credential environment variables
  - requires a public path or public URL that matches the host
  - upload limits should be set higher than the default allowance

---

## docker-compose.yml Requirements

- Use Compose V2 format (`services:` top-level, no `version:` field)
- Declare both networks:
  ```yaml
  networks:
    nginx-proxy:
      external: true
    toolkit-internal:
      driver: bridge
  ```
- `toolkit-landing` gets both networks; all tool containers get `toolkit-internal` only
- No `ports:` entries on any service in production
- `toolkit-landing` may be the only local host-exposed service in the override file
- `restart: unless-stopped` for all services
- `.env` should supply `TZ` and `ROOT_DOMAIN`

---

## `landing/nginx.conf` Requirements

- Listen on port `80`
- Accept the production hostnames derived from `ROOT_DOMAIN` plus localtest.me
- Serve `index.html` from `/usr/share/nginx/html` for requests to `/`
- Keep CyberChef on `/cyberchef/`
- Route all other tools on their own subdomains
- Set standard proxy headers on all proxy blocks
- Redirect bare subpaths without trailing slash to the trailing-slash version
- No logging to disk

### Important note on subdomain compatibility

Some apps are safest on dedicated hosts because they embed absolute asset paths
or expect root-level routing. In this repository:

- Omni Tools and IT Tools are subdomain-only
- Unfurl expects root-level upstream routes
- Parsel and Stegg are repo-local builds and should stay on subdomains
- Network should stay on its own subdomain
- PB / MicroBin needs a dedicated host because of storage, auth, and upload
  settings

---

## Landing Page (`landing/index.html`)

- Plain HTML + CSS only
- No external CDN dependencies
- Clean, simple design
- Displays a site title placeholder
- Links use relative paths or root-relative subpaths so the page works for any
  configured `ROOT_DOMAIN`

---

## Environment Variables

`.env` / `.env.example`:

```text
TZ=America/New_York
ROOT_DOMAIN=domain.com
```

---

## NPM Configuration Notes (manual step, post-deploy)

After `docker compose up -d`, create one proxy host entry in NPM:

1. Domain: `tools.${ROOT_DOMAIN}`
2. Forward hostname: `toolkit-landing`
3. Forward port: `80`
4. Enable Websockets Support
5. SSL: select the existing certificate manually
6. NPM must already be running on the `nginx-proxy` network

---

## Out of Scope (for this phase)

- Automatic certificate issuance or renewal
- Authentication / access control
- Additional tools beyond the documented toolkit set
- Database containers
- Monitoring or logging sidecars

---

## Acceptance Criteria

1. `docker compose up -d` starts all required containers with no errors
2. `toolkit-landing` appears on both `nginx-proxy` and `toolkit-internal`
3. Tool containers appear on `toolkit-internal` only
4. `https://tools.${ROOT_DOMAIN}` loads the landing page
5. `https://tools.${ROOT_DOMAIN}/cyberchef/` loads CyberChef
6. `https://omni.tools.${ROOT_DOMAIN}` loads Omni Tools
7. `https://it.tools.${ROOT_DOMAIN}` loads IT Tools
8. `https://unfurl.tools.${ROOT_DOMAIN}` loads Unfurl
9. `https://parsel.tools.${ROOT_DOMAIN}` loads Parsel
10. `https://stegg.tools.${ROOT_DOMAIN}` loads Stegg
11. `https://network.tools.${ROOT_DOMAIN}` loads Network
12. `https://pb.tools.${ROOT_DOMAIN}` loads PB / MicroBin
13. Bare subpaths without trailing slash redirect correctly
14. No container has a host port binding in production
15. All tool processing remains client-side unless an app explicitly needs a backend
