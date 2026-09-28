# Every key the clients read from window.LOGSEQ_CONFIG (./self-hosting.patch,
# frontend/config.cljs), and the environment variable a web app server fills
# it from (./_webapp-nginx.nix). The one list of what `clientConfig` accepts:
# the build, the runner and services.logseq-webapp all read it from here.
{
  # The OIDC provider to sign in with (the device flow); unset keeps
  # upstream's Cognito login. Same value as the servers' oidcIssuer.
  oidcIssuer = "LOGSEQ_OIDC_ISSUER";
  # The OAuth client id, for the OIDC provider or Cognito alike.
  cognitoClientId = "LOGSEQ_OIDC_CLIENT_ID";
  # Answers POST /file-sync/user_info; point it at the web app.
  apiDomain = "LOGSEQ_API_DOMAIN";
  syncHttpBase = "LOGSEQ_SYNC_HTTP_BASE";
  syncWsUrl = "LOGSEQ_SYNC_WS_URL";
  publishApiBase = "LOGSEQ_PUBLISH_API_BASE";
  # Cognito only: another pool than upstream's.
  oauthDomain = "LOGSEQ_COGNITO_OAUTH_DOMAIN";
  cognitoIdp = "LOGSEQ_COGNITO_IDP";
  userPoolId = "LOGSEQ_COGNITO_USER_POOL_ID";
}
