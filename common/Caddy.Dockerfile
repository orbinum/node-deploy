# Custom Caddy build with the rate-limit plugin (not in the base image).
# https://github.com/mholt/caddy-ratelimit
FROM caddy:2-builder AS build
RUN xcaddy build --with github.com/mholt/caddy-ratelimit

FROM caddy:2-alpine
COPY --from=build /usr/bin/caddy /usr/bin/caddy
