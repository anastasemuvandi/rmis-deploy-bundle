// RMIS frontend production environment — TARGET: server 10.10.73.8 (HTTP).
// build_images.sh swaps this file in for src/environments/environment.prod.ts
// before `ng build --configuration production`, then restores the original.
//
// These values are BAKED INTO THE JS at build time. If the server IP changes,
// edit this file and rebuild the frontend image.
export const environment = {
  production: true,
  apiUrl: '/api',
  // [GoR-SSO] Browser hits the backend's host port (8085) DIRECTLY for SSO, so Spring
  // [GoR-SSO] derives redirect_uri from this host and nginx needn't proxy /oauth2 + /login.
  ssoLoginUrl: 'http://10.10.73.8:8085/oauth2/authorization/gor',
  // [GoR-SSO] RP-initiated (single) logout — browser-facing WRAPPER endpoint (:8000).
  ssoLogoutUrl: 'http://10.10.73.8:8000/oauth2/logout',
  // [GoR-SSO] OIDC client id of this app — REQUIRED by the wrapper on /oauth2/logout
  // [GoR-SSO] whenever post_logout_redirect_uri is supplied.
  ssoClientId: 'rmis-portal',
  // [GoR-SSO] Where the wrapper bounces the browser after ending the SSO session.
  // [GoR-SSO] MUST be registered on the rmis-portal client. SPA is served by nginx on :80.
  postLogoutRedirectUri: 'http://10.10.73.8/login'
};
