**No longer required for a fresh deploy.** Traefik issues and auto-renews
its own wildcard cert via ACME DNS-01 (`CF_DNS_API_TOKEN` in `.env`, see
`rules/routers.yml`'s `wildcard-acme-trigger` router) -- confirmed live in
production since 2026-09-13. This directory and its `docker-compose.yml`
mount (`./certs:/certs:ro`) are legacy from the original NPM import and are
currently unused; left in place rather than ripped out, but a new
deployment doesn't need anything placed here.
