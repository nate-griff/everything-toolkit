# Conversion Toolkit

Self-hosted toolkit stack with one nginx landing/proxy container and three
prebuilt tool containers:

- Omni Tools
- CyberChef
- IT Tools

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
│   └── verify-toolkit.ps1
└── README.md
```

## Local Development

1. Copy `.env.example` to `.env`.
2. Start the stack with:

   ```powershell
   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
   ```

3. Open the stack locally with localtest.me hosts:
   - `http://tools.localtest.me:8080/`
   - `http://tools.localtest.me:8080/cyberchef/`
   - `http://omni.tools.localtest.me:8080/`
   - `http://it.tools.localtest.me:8080/`

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

## Production Notes

- Keep the base `docker-compose.yml` for production so `nginx-proxy` stays an
  external network there.
- NPM should forward all three public hosts to `toolkit-landing:80`:

| Public host | Path | Target app |
| --- | --- | --- |
| `tools.n8-g.com` | `/` | Landing page |
| `tools.n8-g.com` | `/cyberchef/` | CyberChef |
| `omni.tools.n8-g.com` | `/` | Omni Tools |
| `it.tools.n8-g.com` | `/` | IT Tools |

- Recommended NPM settings for each proxy host:
  - Forward hostname: `toolkit-landing`
  - Forward port: `80`
  - Enable Websockets Support
  - Use the existing certificate for the host
- `toolkit-landing` remains the only container attached to both `nginx-proxy`
  and `toolkit-internal`; the tool containers stay internal-only.

### Why Omni and IT Tools moved to subdomains

Omni Tools and IT Tools were moved off subpaths because their SPA routing and
asset loading were not reliable when served under `/omni/` or `/it-tools/`.
Serving them from their own subdomains avoids those breakages.

## Verification

Run the lightweight repository checks:

```powershell
.\tests\verify-toolkit.ps1 scaffold
.\tests\verify-toolkit.ps1 compose
.\tests\verify-toolkit.ps1 proxy
.\tests\verify-toolkit.ps1 landing
.\tests\verify-toolkit.ps1 docs
.\tests\verify-toolkit.ps1 runtime
```

Useful runtime checks:

```powershell
docker compose config
docker compose -f docker-compose.yml -f docker-compose.local.yml ps
docker ps
docker network inspect nginx-proxy
```

Suggested runtime checks:

```powershell
Invoke-WebRequest http://tools.localtest.me:8080/
Invoke-WebRequest http://tools.localtest.me:8080/cyberchef/
Invoke-WebRequest http://omni.tools.localtest.me:8080/
Invoke-WebRequest http://it.tools.localtest.me:8080/
```
