// Faro settings for jbh-web in the local cluster. Kubernetes mounts this file over /srv/runtime-config.js
// (k8s/components/observability/web-runtime-config.yaml). The image's own copy (jbh-app/src/runtime-config.js)
// is empty, so production and mobile builds keep Faro off. /collect is on the same origin as the app (Ingress jbh-faro).
window.__JBH_RUNTIME__ = {
  observability: {
    enabled: true,
    collectorUrl: 'http://localhost:8081/collect',
    environment: 'k8s-local'
  }
};
