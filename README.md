# Conversion Toolkit

Self-hosted toolkit stack with one nginx landing/proxy container, three
prebuilt tool containers, and one locally built tool container:

- Omni Tools
- CyberChef
- IT Tools
- Unfurl

Production uses Nginx Proxy Manager (NPM) to send every public host to the
`toolkit-landing:80` container. The landing page then routes users to the right
tool. Tool containers stay internal-only on `toolkit-internal`.

## Repository Structure

```text
.
├── docker-compose.yml
├── docker-compose.local.yml
├── .env.example
├── landing/
│   ├── index.html
│   └── nginx.conf
├── tests/
│   ├── verify-toolkit.ps1
│   └── verify-toolkit.sh
├── unfurl/
│   └── unfurl.ini
└── README.md
```

## Local Development

1. Copy `.env.example` to `.env`.

   **PowerShell**

   ```powershell
   Copy-Item .env.example .env
   ```

   **Bash**

   ```bash
   cp .env.example .env
   ```

2. Start the stack with:

   **PowerShell**

   ```powershell
   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
   ```

   **Bash**

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
   ```

   On the first run, Docker Compose builds Unfurl with the local
   `unfurl/Dockerfile`. That Dockerfile clones the pinned `RyanDFIR/unfurl`
   commit during the image build. If the pinned ref changes later, rebuild it with:

   **PowerShell**

   ```powershell
   docker compose -f docker-compose.yml -f docker-compose.local.yml build unfurl
   ```

   **Bash**

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.local.yml build unfurl
   ```

   The build currently uses:
   - `git clone https://github.com/RyanDFIR/unfurl /unfurl`
   - pinned commit `2d2dac375433d2a7fbeede2d25c5f19b68d4d244`

3. Open the stack locally with localtest.me hosts:
    - `http://tools.localtest.me:8080/`
    - `http://tools.localtest.me:8080/cyberchef/`
    - `http://omni.tools.localtest.me:8080/`
    - `http://it.tools.localtest.me:8080/`
    - `http://unfurl.tools.localtest.me:8080/`

`localtest.me` resolves to `127.0.0.1`, so basic testing works without editing
your hosts file.

The local override publishes only `toolkit-landing` on port `8080`. The tool
containers remain unexposed.

### Local routing map

| URL | App |
| --- | --- |
| `http://tools.localtest.me:8080/` | Landing page |
| `http://tools.localtest.me:8080/cyberchef/` | CyberChef |
| `http://omni.tools.localtest.me:8080/` | Omni Tools |
| `http://it.tools.localtest.me:8080/` | IT Tools |
| `http://unfurl.tools.localtest.me:8080/` | Unfurl |

## Production Notes

- Keep the base `docker-compose.yml` for production so `nginx-proxy` stays an
  external network there.
- NPM should forward all four public hosts to `toolkit-landing:80`:

| Public host | Path | Target app |
| --- | --- | --- |
| `tools.n8-g.com` | `/` | Landing page |
| `tools.n8-g.com` | `/cyberchef/` | CyberChef |
| `omni.tools.n8-g.com` | `/` | Omni Tools |
| `it.tools.n8-g.com` | `/` | IT Tools |
| `unfurl.tools.n8-g.com` | `/` | Unfurl |

- Recommended NPM settings for each proxy host:
  - Forward hostname: `toolkit-landing`
  - Forward port: `80`
  - Enable Websockets Support
  - Use the existing certificate for the host
- `toolkit-landing` remains the only container attached to both `nginx-proxy`
  and `toolkit-internal`; the tool containers stay internal-only.

### Why some tools use subdomains

Omni Tools and IT Tools were moved off subpaths because their SPA routing and
asset loading were not reliable when served under `/omni/` or `/it-tools/`.
Serving them from their own subdomains avoids those breakages.

Unfurl also runs on its own subdomain. Its upstream Flask app assumes root-level
routes such as `/`, `/graph`, `/json/visjs`, and `/static/*`, so proxying it
under `/unfurl/` would require patching upstream behavior. The landing page
keeps a relative `/unfurl/` link, and `toolkit-landing` redirects that path to
the Unfurl subdomain. The repository does not vendor the upstream source; the
local `unfurl/Dockerfile` clones the pinned commit during image build instead.

## Verification

Run the lightweight repository checks:

**PowerShell**

```powershell
.\tests\verify-toolkit.ps1 scaffold
.\tests\verify-toolkit.ps1 compose
.\tests\verify-toolkit.ps1 proxy
.\tests\verify-toolkit.ps1 landing
.\tests\verify-toolkit.ps1 docs
.\tests\verify-toolkit.ps1 runtime
```

**Bash**

```bash
bash ./tests/verify-toolkit.sh scaffold
bash ./tests/verify-toolkit.sh compose
bash ./tests/verify-toolkit.sh proxy
bash ./tests/verify-toolkit.sh landing
bash ./tests/verify-toolkit.sh docs
bash ./tests/verify-toolkit.sh runtime
```

Useful runtime checks:

```powershell
docker compose config
docker compose -f docker-compose.yml -f docker-compose.local.yml build unfurl
docker compose -f docker-compose.yml -f docker-compose.local.yml ps
docker ps
docker network inspect nginx-proxy
```

Suggested runtime checks:

**PowerShell**

```powershell
Invoke-WebRequest http://tools.localtest.me:8080/
Invoke-WebRequest http://tools.localtest.me:8080/cyberchef/
Invoke-WebRequest http://omni.tools.localtest.me:8080/
Invoke-WebRequest http://it.tools.localtest.me:8080/
Invoke-WebRequest http://unfurl.tools.localtest.me:8080/
```

**Bash**

```bash
curl -I http://tools.localtest.me:8080/
curl -I http://tools.localtest.me:8080/cyberchef/
curl -I http://omni.tools.localtest.me:8080/
curl -I http://it.tools.localtest.me:8080/
curl -I http://unfurl.tools.localtest.me:8080/
```
