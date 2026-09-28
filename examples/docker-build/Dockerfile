# Docker-native front door onto logseq-webapp-image's clientConfig: set
# --build-arg instead of learning Nix override syntax. The `nix build`
# output is already a docker-loadable tar.gz (dockerTools.buildLayeredImage);
# this Dockerfile's only job is producing that one file as a build
# artifact, not as a runnable image in its own right — trying to make the
# final stage directly runnable would mean ingesting an externally-built
# OCI tar as one of its own layers, which a Dockerfile has no instruction
# for. So the last stage is `scratch` holding just that file, and
# `--output type=local` exports it straight to the host instead of via
# `docker load` twice (once here, once for real).
#
# Build (needs network for the RUN below, and an exporter for --output —
# both plain `docker build`-with-buildx and `podman build` support both;
# classic non-buildx `docker build` supports neither):
#
#   podman build --network host -o type=local,dest=out \
#     -f examples/docker-build/Dockerfile .
#   docker buildx build --network host --output type=local,dest=out \
#     -f examples/docker-build/Dockerfile .
#
# Then `./load-image.sh out/result` (or `podman load -i out/result`).
FROM nixos/nix:latest AS builder

# Same 9 keys as _common.nix's defaultClientConfig; each ARG defaults to the
# matching upstream value, so an unset --build-arg reproduces the plain
# image exactly. OIDC_DEVICE_FLOW is the one boolean (hence --argjson below):
# true swaps the Cognito login form for the OAuth device flow.
ARG COGNITO_CLIENT_ID=69cs1lgme7p8kbgld8n5kseii6
ARG OAUTH_DOMAIN=logseq-prod.auth.us-east-1.amazoncognito.com
ARG API_DOMAIN=api.logseq.com
ARG COGNITO_IDP=https://cognito-idp.us-east-1.amazonaws.com/
ARG USER_POOL_ID=us-east-1_dtagLnju8
ARG PUBLISH_API_BASE=https://logseq.io
ARG SYNC_WS_URL=wss://api.logseq.io/sync/%s
ARG SYNC_HTTP_BASE=https://api.logseq.io
ARG OIDC_DEVICE_FLOW=false

RUN mkdir -p /etc/nix \
    && echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

COPY . /src

# jq -n --arg, not shell interpolation: several of these values contain
# characters (: / %) that break naive `"{\"x\": \"$VAR\"}"` quoting.
RUN nix shell nixpkgs#jq -c jq -n \
      --arg cognitoClientId "$COGNITO_CLIENT_ID" \
      --arg oauthDomain "$OAUTH_DOMAIN" \
      --arg apiDomain "$API_DOMAIN" \
      --arg cognitoIdp "$COGNITO_IDP" \
      --arg userPoolId "$USER_POOL_ID" \
      --arg publishApiBase "$PUBLISH_API_BASE" \
      --arg syncWsUrl "$SYNC_WS_URL" \
      --arg syncHttpBase "$SYNC_HTTP_BASE" \
      --argjson oidcDeviceFlow "$OIDC_DEVICE_FLOW" \
      '$ARGS.named' > /src/examples/docker-build/client-config.json \
    # path:, never a bare `.#...`/`git+file://` ref: this repo's git objects
    # are sha256 and Nix's git fetcher only understands sha1, so anything
    # that goes through the git fetcher fails here. path: instead copies the
    # tree and evaluates it directly. Don't "simplify" this back to a bare
    # ref later.
    && nix build 'path:/src#logseq-webapp-docker-image' -o /result

FROM scratch
COPY --from=builder /result/*.tar.gz /result
