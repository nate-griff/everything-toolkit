# Copilot Instructions

## Commands

- **Initialize local env:** `Copy-Item .env.example .env`
- **Start the local stack:** `docker compose -f docker-compose.yml -f docker-compose.local.yml up -d`
- **Rebuild the locally built Unfurl service:** `docker compose -f docker-compose.yml -f docker-compose.local.yml build unfurl`
- **Inspect the running local stack:** `docker compose -f docker-compose.yml -f docker-compose.local.yml ps`
- **Render merged Compose config:** `docker compose config`
- **Run repository verification:** `.\tests\verify-toolkit.ps1 <suite>`
- **Run one verification suite:** `.\tests\verify-toolkit.ps1 landing`
- **Available suites:** `scaffold`, `compose`, `proxy`, `landing`, `docs`, `runtime`
- **Bash equivalent for verification:** `bash ./tests/verify-toolkit.sh <suite>`

There is no separate lint or build pipeline in this repo. Validation is done through the verification scripts plus Docker Compose checks.

## High-level architecture

This repository defines a small self-hosted toolkit stack in Docker Compose. `toolkit-landing` is an `nginx:alpine` container that serves the static landing page from `landing/index.html` and applies the reverse-proxy rules from `landing/nginx.conf`. Omni Tools, CyberChef, and IT Tools are pulled from published images. Unfurl is the exception: it is built from the repo-local `unfurl/Dockerfile`, which clones a pinned `RyanDFIR/unfurl` commit during image build and reads runtime settings from `unfurl/unfurl.ini`.

Networking is the main architectural constraint. `toolkit-landing` is the only container attached to both `nginx-proxy` and `toolkit-internal`; the tool containers stay on `toolkit-internal` only and should never be exposed directly. In production, Nginx Proxy Manager forwards the public hosts to `toolkit-landing`, and `landing/nginx.conf` handles the final routing split: the landing page and CyberChef stay on `tools.*`, while Omni Tools, IT Tools, and Unfurl are served from their own `*.tools.*` subdomains. The landing page still uses relative `/omni/`, `/it-tools/`, and `/unfurl/` links, so nginx redirect rules must continue mapping those paths to the correct subdomain host.

## Key conventions

- Keep `docker-compose.yml` production-oriented: no host `ports:` on any service, `nginx-proxy` remains external there, and every service uses `restart: unless-stopped`.
- Put local-only exposure in `docker-compose.local.yml`, and only expose `toolkit-landing` on `8080`. The tool containers should remain internal-only even locally.
- Treat `landing/index.html` as a static document: plain HTML with inline CSS, no JavaScript frameworks, and no external CDN dependencies.
- Preserve the hostname-aware redirect behavior in `landing/nginx.conf`. Redirects are expected to honor `X-Forwarded-Proto` and derive the Omni, IT Tools, and Unfurl subdomains from the incoming host so both production domains and `tools.localtest.me:8080` work without hard-coded local values.
- Keep Unfurl pinned to an explicit upstream Git ref in `unfurl/Dockerfile` instead of building from an unpinned branch, and keep its config in `unfurl/unfurl.ini` so the container binds to `0.0.0.0:5000`.
- Keep docs and verification in sync. If routing, hostnames, build sources, ports, or command examples change, update `README.md`, `tests\verify-toolkit.ps1`, and `tests\verify-toolkit.sh` together; the verification scripts treat those details as part of the contract.
