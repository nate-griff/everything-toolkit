# Conversion Toolkit — Requirements Document

## Overview

A self-hosted web toolkit served internally at `tools.n8-g.com`. A custom landing
page acts as the hub and also reverse-proxies to each tool container at a subpath.
All services are defined in a single `docker-compose.yml` in one repository.

TLS and external domain routing are handled by an existing Nginx Proxy Manager (NPM)
instance. NPM forwards all traffic for `tools.n8-g.com` to the `toolkit-landing`
container. Tool containers are isolated on a private internal network — they are not
reachable from NPM or any other container on the host except `toolkit-landing`.

No tool source code is cloned — all containers use pre-published Docker images.

---

## Repository Structure

```
toolkit/
├── docker-compose.yml
├── .env                    # gitignored
├── .env.example            # committed, documents all required vars
├── landing/
│   ├── index.html          # static landing page
│   └── nginx.conf          # nginx config: serves landing page + proxies subpaths
└── README.md
```

---

## Networking

Two networks are used:

| Network            | Type                        | Purpose                                                  |
|--------------------|-----------------------------|----------------------------------------------------------|
| `nginx-proxy`      | external (pre-existing)     | NPM → `toolkit-landing` only                             |
| `toolkit-internal` | bridge, created by compose  | `toolkit-landing` → tool containers only                 |

- `toolkit-landing` is the **only** container on both networks
- Tool containers (`omni-tools`, `cyberchef`, `it-tools`) are on `toolkit-internal` only
- Tool containers are not reachable from NPM or any other container on `nginx-proxy`

```
NPM (nginx-proxy) ──► toolkit-landing (nginx-proxy + toolkit-internal)
                                │
                    ┌───────────┼───────────┐
                    ▼           ▼           ▼
               omni-tools   cyberchef   it-tools
               (toolkit-internal only)
```

NPM proxy host entry (one entry, configured manually after deploy):

| NPM Proxy Host       | Forward Hostname  | Forward Port |
|----------------------|-------------------|--------------|
| `tools.n8-g.com` | `toolkit-landing` | `80`         |

Subpath routing handled by `toolkit-landing` nginx:

| Subpath       | Proxied To   | Internal Port |
|---------------|--------------|---------------|
| `/`           | index.html   | —             |
| `/omni/`      | `omni-tools` | `80`          |
| `/cyberchef/` | `cyberchef`  | `8000`        |
| `/it-tools/`  | `it-tools`   | `80`          |

> CyberChef internal port: `mpepping/cyberchef` exposes `8000`. Verify against the
> chosen image before finalizing nginx.conf proxy_pass targets.

---

## Services

### 1. Landing + Proxy — `toolkit-landing`
- **Image:** `nginx:alpine`
- **Purpose:** Serves `index.html` at `/` and reverse-proxies subpaths to tool
  containers over `toolkit-internal`
- **Volumes:**
  - `./landing/index.html:/usr/share/nginx/html/index.html:ro`
  - `./landing/nginx.conf:/etc/nginx/conf.d/default.conf:ro`
- **Networks:** `nginx-proxy`, `toolkit-internal`
- **No host port bindings**
- **restart:** `unless-stopped`

### 2. omni-tools — `omni-tools`
- **Image:** `iib0011/omni-tools:latest`
- **Purpose:** General-purpose browser-based utilities (PDF, image, text/list
  manipulation, data format conversion, calculations)
- **Internal port:** `80`
- **No volumes required** — stateless, all processing in-browser
- **Networks:** `toolkit-internal` only
- **No host port bindings**
- **restart:** `unless-stopped`

### 3. CyberChef — `cyberchef`
- **Image:** `mpepping/cyberchef:latest`
  - Alternative official image: `ghcr.io/gchq/cyberchef:latest`
  - Confirm which image to use and verify its internal port before writing nginx.conf
- **Purpose:** Data encoding/decoding, encryption, hashing, format conversion
- **Internal port:** `8000` (verify against chosen image)
- **No volumes required** — stateless, all processing in-browser
- **Networks:** `toolkit-internal` only
- **No host port bindings**
- **restart:** `unless-stopped`

### 4. it-tools — `it-tools`
- **Image:** `corentinth/it-tools:latest`
- **Purpose:** Developer utilities (tokens, hashes, QR codes, converters, formatters,
  network tools)
- **Internal port:** `80`
- **No volumes required** — stateless, all processing in-browser
- **Networks:** `toolkit-internal` only
- **No host port bindings**
- **restart:** `unless-stopped`

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
- No `ports:` entries on any service
- No `build:` steps — all images pulled from registries
- All services set `restart: unless-stopped`
- `.env` loaded automatically by Compose
- `toolkit-landing` mounts `./landing/index.html` and `./landing/nginx.conf` read-only

---

## `landing/nginx.conf` Requirements

- Listen on port `80`
- `server_name _` (accept any hostname — NPM handles the real domain)
- Serve `index.html` from `/usr/share/nginx/html` for requests to `/`
- For each tool subpath, strip the prefix before proxying so the tool app receives
  requests at its own root (e.g. `/omni/foo` → `http://omni-tools:80/foo`):
  - `location /omni/` → `proxy_pass http://omni-tools:80/`
  - `location /cyberchef/` → `proxy_pass http://cyberchef:8000/`
  - `location /it-tools/` → `proxy_pass http://it-tools:80/`
- Set standard proxy headers on all proxy blocks:
  ```
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
  ```
- Redirect bare subpaths without trailing slash to the trailing-slash version
  (e.g. `/omni` → `/omni/`) to prevent broken relative asset paths
- No logging to disk (stdout/stderr only)

### Important note on subpath compatibility

Some single-page apps (SPAs) embed absolute asset paths (e.g. `/static/main.js`)
that break when served under a subpath, because the app still requests assets at `/`
rather than `/omni/`. The agent should be aware that:
- **omni-tools** and **it-tools** are React/Vue SPAs and may have this issue
- **CyberChef** is generally subpath-tolerant
- If asset loading breaks for a tool and cannot be fixed in nginx.conf alone, that
  tool should be broken out to its own NPM subdomain proxy host as a fallback, with
  a note added to the README explaining why

---

## Landing Page (`landing/index.html`)

- Plain HTML + CSS only — no JavaScript frameworks
- No external CDN dependencies (fully offline-capable after first load)
- Clean, simple design — dark or neutral theme
- Displays a site title (placeholder: **"Tools"** — user to finalize)
- Three cards or link tiles, one per tool, each opening in a new tab:

  | Card Label | URL           | Description                                     |
  |------------|---------------|-------------------------------------------------|
  | Omni Tools | `/omni/`      | General-purpose browser tools                   |
  | CyberChef  | `/cyberchef/` | Encoding, decoding, encryption, data analysis   |
  | IT Tools   | `/it-tools/`  | Developer utilities: tokens, hashes, formatters |

- Links use relative subpaths (not absolute URLs) so the page works regardless of
  what domain NPM is configured with

---

## Environment Variables

`.env` / `.env.example`:
```
# Timezone
TZ=America/New_York
```

No secrets required for this phase — all tool images are unauthenticated and stateless.

---

## NPM Configuration Notes (manual step, post-deploy)

After `docker compose up -d`, create one proxy host entry in NPM:
1. Domain: `tools.n8-g.com`
2. Forward hostname: `toolkit-landing`
3. Forward port: `80`
4. Enable "Websockets Support" (recommended for SPAs)
5. SSL: use existing Let's Encrypt / Cloudflare certificate
6. NPM must already be running on the `nginx-proxy` network (assumed true)

---

## Out of Scope (for this phase)

- Authentication / access control
- ConvertX, Stirling-PDF, or any additional tools
- Database containers
- Monitoring or logging sidecars

---

## Acceptance Criteria

1. `docker compose up -d` starts all four containers with no errors
2. `toolkit-landing` appears on both `nginx-proxy` and `toolkit-internal`
3. Tool containers appear on `toolkit-internal` only — not on `nginx-proxy`
   (`docker network inspect nginx-proxy` should show only `toolkit-landing`)
4. `https://tools.n8-g.com` loads the landing page
5. `https://tools.n8-g.com/omni/` loads omni-tools fully (assets load correctly)
6. `https://tools.n8-g.com/cyberchef/` loads CyberChef fully
7. `https://tools.n8-g.com/it-tools/` loads IT Tools fully
8. Bare subpaths without trailing slash redirect correctly (e.g. `/omni` → `/omni/`)
9. No container has a host port binding (`docker ps` shows no `0.0.0.0:xxxx` entries)
10. All tool processing remains client-side — no external service calls