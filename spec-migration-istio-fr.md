# Spec de migration — Istio multi-cluster avec gateway interne

**Version :** 1.1  
**Statut :** Draft  
**Langue :** Français  
**Contexte :** Rancher on-prem/hybride — sidecars déjà présents, pas de mTLS ni d'auth active, Nginx Ingress sans Gateway API CRD

---

## Table des matières

1. [Résumé exécutif](#1-résumé-exécutif)
2. [Architecture cible](#2-architecture-cible)
3. [Cluster ingress — Gateway nord-sud](#3-cluster-ingress--gateway-nord-sud)
4. [Cluster workload — Gateway interne datacenter](#4-cluster-workload--gateway-interne-datacenter)
5. [Validation JWT — RequestAuthentication native Istio (RS512)](#5-validation-jwt--requestauthentication-native-istio-rs512)
6. [Contrôle de schéma — ExtAuthz](#6-contrôle-de-schéma--extauthz)
7. [mTLS — Migration PERMISSIVE → STRICT](#7-mtls--migration-permissive--strict)
8. [Cert-manager et gestion des certificats](#8-cert-manager-et-gestion-des-certificats)
9. [Observabilité](#9-observabilité)
10. [Phases de migration et plan de rollback](#10-phases-de-migration-et-plan-de-rollback)
11. [Décisions ouvertes](#11-décisions-ouvertes)

---

## 1. Résumé exécutif

### Situation actuelle

| Composant | État |
|---|---|
| Sidecars Istio | Déployés, mais en mode passif |
| mTLS | Désactivé (mode DISABLE ou absent) |
| Authentification | Aucune (pas de RequestAuthentication, pas d'ExtAuthz) |
| Ingress | Nginx Ingress Controller — sans Gateway API CRD |
| Cluster | Unique, Rancher on-prem/hybride |

### Objectif

Passer à une architecture deux clusters :

| Cluster | Rôle |
|---|---|
| **ingress-cluster** | Termine tout le trafic nord-sud externe. Istio IngressGateway, validation JWT native, contrôle de schéma ExtAuthz. Aucun workload applicatif. |
| **workload-cluster** | Exécute les services applicatifs. Reçoit le trafic externe via le gateway est-ouest depuis l'ingress-cluster, et le trafic interne datacenter via un gateway dédié (réseau de confiance, sans auth). |

### Points clés de cette révision

- **Gateway interne** ajouté sur le workload-cluster pour les flux HTTP/HTTPS et gRPC provenant du datacenter, sans authentification applicative (réseau de confiance).
- **Validation JWT** migrée vers `RequestAuthentication` natif Istio avec RS512 — sans injection d'en-têtes enrichis.
- **Contrôle de schéma OpenAPI** maintenu via ExtAuthz (gRPC) sur l'ingress-cluster.
- **mTLS** activé en mode PERMISSIVE d'abord, puis migration vers STRICT par namespace.

---

## 2. Architecture cible

```
                        ┌─────────────────────────────────────────────────┐
  Internet              │              INGRESS CLUSTER                     │
  ─────────             │                                                  │
  HTTPS/gRPC ─────────► │  [Load Balancer :443]                           │
                        │       │                                          │
                        │  [Istio IngressGateway]                         │
                        │       │  Terminaison TLS (cert-manager)          │
                        │       │                                          │
                        │       ├──── RequestAuthentication (RS512) ───►  │
                        │       │     Vérif JWT native istiod              │
                        │       │     Rejet 401 si token invalide          │
                        │       │                                          │
                        │       ├──── ExtAuthz (gRPC) ────────────────►   │
                        │       │     Contrôle schéma OpenAPI              │
                        │       │     Rejet 400/404/413/415 si invalide    │
                        │       │                                          │
                        │       ▼                                          │
                        │  [VirtualService routing]                       │
                        │       │                                          │
                        │  [East-West Gateway :15443]                     │
                        │       │  mTLS SPIFFE/SVID (AUTO_PASSTHROUGH)    │
                        └───────┼─────────────────────────────────────────┘
                                │
                        ┌───────┼─────────────────────────────────────────┐
                        │       ▼         WORKLOAD CLUSTER                 │
                        │  [East-West Gateway :15443]                     │
                        │       │  Trafic depuis ingress-cluster           │
                        │       │                                          │
                        │  [Internal Gateway :80/:443/:50051]             │
                        │       │  Trafic datacenter interne               │
                        │       │  HTTP/HTTPS + gRPC                       │
                        │       │  Réseau de confiance — pas d'auth        │
                        │       │                                          │
                        │       ▼                                          │
                        │  [Service A]  [Service B]  [Service N]          │
                        │  (sidecar)    (sidecar)    (sidecar)            │
                        │  PeerAuthentication: PERMISSIVE → STRICT        │
                        └─────────────────────────────────────────────────┘
                                ▲
  Datacenter interne ───────────┘
  (réseau de confiance)
```

---

## 3. Cluster ingress — Gateway nord-sud

### 3.1 Installation Istio

```yaml
# ingress-cluster-istio.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: ingress-primary
spec:
  profile: default
  meshConfig:
    accessLogFile: /dev/stdout
    extensionProviders:
      - name: ext-authz-schema
        envoyExtAuthzGrpc:
          service: ext-authz.ext-authz.svc.cluster.local
          port: 9000
          timeout: 5s
          statusOnError: DENY          # fail-closed — rejet si ExtAuthz injoignable
  components:
    egressGateways:
      - name: istio-egressgateway
        enabled: false
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          service:
            ports:
              - port: 443
                targetPort: 8443
                name: https
              - port: 50051
                targetPort: 50051
                name: grpc
      - name: istio-eastwestgateway
        enabled: true
        label:
          istio: eastwestgateway
          topology.istio.io/network: ingress-network
        k8s:
          env:
            - name: ISTIO_META_ROUTER_MODE
              value: sni-dnat
          service:
            ports:
              - port: 15443
                targetPort: 15443
                name: tls
```

### 3.2 Gateway resource (nord-sud)

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: external-gateway
  namespace: istio-ingress
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: ingress-tls-secret   # géré par cert-manager
      hosts:
        - "api.example.com"
    - port:
        number: 50051
        name: grpc-tls
        protocol: HTTPS                      # gRPC sur TLS = HTTPS au sens Istio
      tls:
        mode: SIMPLE
        credentialName: ingress-tls-secret
      hosts:
        - "grpc.example.com"
```

### 3.3 VirtualService (routage vers est-ouest)

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: api-route
  namespace: istio-ingress
spec:
  hosts:
    - "api.example.com"
  gateways:
    - external-gateway
  http:
    - route:
        - destination:
            host: service-a.app-namespace.svc.cluster.local
            port:
              number: 80
```

---

## 4. Cluster workload — Gateway interne datacenter

### 4.1 Rôle et périmètre

Ce gateway reçoit les flux HTTP/HTTPS et gRPC **provenant du datacenter interne uniquement**. Il n'est **pas exposé sur Internet**. Aucune validation JWT ni ExtAuthz n'est appliquée : le réseau d'origine est considéré de confiance.

La restriction d'accès repose sur :
- L'IP source (NetworkPolicy ou firewall réseau) — seules les plages IP internes peuvent atteindre ce gateway.
- À terme (phase STRICT) : un `AuthorizationPolicy` peut exiger que le trafic arrive via ce gateway spécifique (label selector).

### 4.2 Déploiement du gateway interne

```yaml
# internal-gateway-deployment.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: internal-gateway
  namespace: istio-system
spec:
  profile: empty
  components:
    ingressGateways:
      - name: istio-internalgateway
        namespace: istio-internal
        enabled: true
        label:
          istio: internalgateway
          app: istio-internalgateway
        k8s:
          service:
            type: LoadBalancer           # LB interne uniquement — annotation ci-dessous
            loadBalancerSourceRanges:    # Restreindre aux CIDR datacenter
              - "10.0.0.0/8"
              - "172.16.0.0/12"
            ports:
              - port: 80
                targetPort: 8080
                name: http
              - port: 443
                targetPort: 8443
                name: https
              - port: 50051
                targetPort: 50051
                name: grpc
```

> **Note :** Sur Rancher/on-prem, utiliser `type: ClusterIP` avec un proxy ou un MetalLB interne selon l'infrastructure réseau. L'annotation `loadBalancerSourceRanges` filtre au niveau du LB cloud, mais n'est pas disponible sur MetalLB — compenser avec une NetworkPolicy.

### 4.3 Gateway resource (interne)

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: internal-gateway
  namespace: istio-internal
spec:
  selector:
    istio: internalgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.internal.example.com"
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: internal-tls-secret  # cert-manager, CA interne
      hosts:
        - "*.internal.example.com"
    - port:
        number: 50051
        name: grpc
        protocol: GRPC
      hosts:
        - "*.internal.example.com"
```

### 4.4 VirtualService associé

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: service-a-internal
  namespace: app-namespace
spec:
  hosts:
    - "service-a.internal.example.com"
  gateways:
    - istio-internal/internal-gateway
  http:
    - route:
        - destination:
            host: service-a.app-namespace.svc.cluster.local
            port:
              number: 80
```

### 4.5 NetworkPolicy — restriction aux flux internes

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-internal-gateway-only
  namespace: istio-internal
spec:
  podSelector:
    matchLabels:
      istio: internalgateway
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: 10.0.0.0/8        # Adapter aux CIDR datacenter
        - ipBlock:
            cidr: 172.16.0.0/12
```

---

## 5. Validation JWT — RequestAuthentication native Istio (RS512)

### 5.1 Principe

La validation JWT est déléguée à **istiod** via `RequestAuthentication`. Istiod gère :
- Le cache JWKS (rafraîchi automatiquement selon le TTL du endpoint).
- La vérification cryptographique de la signature (RS512).
- Le rejet avec `401 Unauthorized` si le token est absent ou invalide.

**Aucune injection d'en-têtes** n'est configurée (pas de `outputClaimToHeaders`).

### 5.2 Configuration — IdP unique (recommandé)

Si un seul IdP est utilisé pour les flux externes et internes :

```yaml
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: jwt-external
  namespace: istio-ingress
spec:
  selector:
    matchLabels:
      app: istio-ingressgateway
  jwtRules:
    - issuer: "https://idp.example.com"
      jwksUri: "https://idp.example.com/.well-known/jwks.json"
      audiences:
        - "api.example.com"
      forwardOriginalToken: false
      # Pas d'outputClaimToHeaders — comportement demandé
```

> **RS512** : Istio supporte RS512 nativement. Aucune configuration supplémentaire n'est requise — l'algorithme est détecté depuis le champ `alg` du JWT et vérifié contre la clé publique du JWKS.

### 5.3 Configuration — deux IdPs distincts (si décision future)

Si l'IdP pour les flux internes est différent, ajouter une règle supplémentaire :

```yaml
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: jwt-external
  namespace: istio-ingress
spec:
  selector:
    matchLabels:
      app: istio-ingressgateway
  jwtRules:
    - issuer: "https://idp-externe.example.com"
      jwksUri: "https://idp-externe.example.com/.well-known/jwks.json"
      audiences:
        - "api.example.com"
      forwardOriginalToken: false
    - issuer: "https://idp-interne.example.com"
      jwksUri: "https://idp-interne.example.com/.well-known/jwks.json"
      audiences:
        - "internal.example.com"
      forwardOriginalToken: false
```

> Istiod teste chaque règle dans l'ordre et applique la première qui correspond au champ `iss` du token.

### 5.4 AuthorizationPolicy — rejeter les requêtes sans token valide

`RequestAuthentication` seul **ne rejette pas** les requêtes sans token — il valide seulement si un token est présent. Pour rejeter les requêtes non authentifiées, ajouter :

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: istio-ingress
spec:
  selector:
    matchLabels:
      app: istio-ingressgateway
  action: DENY
  rules:
    - from:
        - source:
            notRequestPrincipals: ["*"]   # Deny si pas de principal JWT valide
      to:
        - operation:
            hosts: ["api.example.com"]
```

### 5.5 Flux de validation complet

```
Client envoie : Authorization: Bearer <token>
                        │
                        ▼
          istiod récupère JWKS (cache 5 min)
                        │
                        ▼
              Vérifie alg == RS512
              Vérifie signature avec clé publique kid correspondante
                        │
                    ┌───┴────────────┐
                    │                │
                 Valide           Invalide
                    │                │
                    ▼                ▼
          Passe à ExtAuthz      401 Unauthorized
          (contrôle schéma)
```

### 5.6 Gateway interne — pas de JWT

Le gateway interne (`istio-internalgateway`) ne porte **aucune** `RequestAuthentication` ni `AuthorizationPolicy` JWT. Le réseau est de confiance — seule la restriction réseau (NetworkPolicy / CIDR) protège l'accès.

---

## 6. Contrôle de schéma — ExtAuthz

### 6.1 Rôle dans l'architecture

ExtAuthz intervient **après** la validation JWT native d'Istio, uniquement sur le chemin de l'ingress externe. Il se charge exclusivement du contrôle de schéma OpenAPI :

```
JWT valide (istiod)  →  ExtAuthz (schéma)  →  VirtualService  →  Service
```

Il n'effectue **pas** de validation JWT — cette responsabilité appartient désormais à `RequestAuthentication`.

### 6.2 Câblage via AuthorizationPolicy CUSTOM

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: ext-authz-schema
  namespace: istio-ingress
spec:
  selector:
    matchLabels:
      app: istio-ingressgateway
  action: CUSTOM
  provider:
    name: ext-authz-schema          # Correspond à meshConfig.extensionProviders[].name
  rules:
    - to:
        - operation:
            hosts: ["api.example.com", "grpc.example.com"]
```

### 6.3 Flux de contrôle de schéma

```
1. Correspondance path + méthode → operationId (spec OpenAPI versionnée)
   └─ Aucune correspondance → 404 Not Found

2. Validation des en-têtes requis
   └─ En-tête manquant ou invalide → 400 Bad Request

3. Validation des paramètres de query string
   └─ Paramètre requis absent → 400 Bad Request

4. Vérification du Content-Type
   └─ Type inattendu → 415 Unsupported Media Type

5. Validation du body (JSON Schema)
   └─ Corps invalide → 400 Bad Request avec message d'erreur structuré

6. Vérification de la taille du corps
   └─ Taille dépassée → 413 Content Too Large

7. Succès → forward vers gateway
```

### 6.4 Interface gRPC ExtAuthz

ExtAuthz implémente le proto `envoy.service.auth.v3.Authorization` :

```protobuf
service Authorization {
  rpc Check(CheckRequest) returns (CheckResponse);
}
```

Codes de retour utilisés :

| Code gRPC | Traduction HTTP | Cas |
|---|---|---|
| `OK` | — | Requête valide, forwarded |
| `INVALID_ARGUMENT` | 400 | Schéma invalide |
| `NOT_FOUND` | 404 | Route inconnue |
| `PERMISSION_DENIED` | 403 | Refus explicite |
| `RESOURCE_EXHAUSTED` | 413 | Corps trop grand |

### 6.5 Chargement des specs OpenAPI

Le service ExtAuthz charge les specs depuis un ConfigMap ou un volume monté, clé de cache : `{service}:{api-version}`. Un endpoint `/reload` (ou un watch Kubernetes) permet la mise à jour sans redémarrage.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: openapi-specs
  namespace: ext-authz
data:
  service-a-v1.yaml: |
    openapi: "3.0.0"
    paths:
      /items:
        get: ...
        post: ...
```

---

## 7. mTLS — Migration PERMISSIVE → STRICT

### 7.1 Principe de la migration

Les sidecars sont déjà déployés mais mTLS est inactif. La migration se fait en deux temps pour éviter toute coupure :

| Phase | Mode | Comportement |
|---|---|---|
| **PERMISSIVE** | Actif dès Phase 1 | Les sidecars acceptent mTLS **et** HTTP en clair — rétrocompatible |
| **STRICT** | Actif en Phase 3 | Les sidecars n'acceptent **que** mTLS — tout trafic en clair est rejeté |

### 7.2 Activation PERMISSIVE (global)

Appliquer sur **les deux clusters** dès le début de la migration :

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system   # Portée mesh-wide
spec:
  mtls:
    mode: PERMISSIVE
```

### 7.3 Migration vers STRICT — par namespace

Ne passer en STRICT que lorsque **tout le trafic vers ce namespace est confirmé mTLS** via les métriques Istio.

```yaml
# À appliquer namespace par namespace, après validation
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: app-namespace   # Scope namespace uniquement
spec:
  mtls:
    mode: STRICT
```

### 7.4 Vérification avant passage en STRICT

Requête PromQL pour détecter le trafic en clair sur un namespace :

```promql
# Trafic non-mTLS entrant sur le namespace app-namespace
sum(
  istio_requests_total{
    destination_service_namespace="app-namespace",
    connection_security_policy="none"
  }
) by (source_workload, destination_service_name)
```

Si le résultat est > 0, identifier la source avant de passer en STRICT.

### 7.5 Cas du gateway interne (datacenter)

Le trafic datacenter arrive via le gateway interne (`istio-internalgateway`). Ce gateway **a un sidecar** et peut établir mTLS vers les services workload. Côté datacenter source (hors cluster), le trafic arrive en HTTP/HTTPS plain vers le gateway — ce qui est acceptable en STRICT car la règle STRICT s'applique au trafic **entre sidecars**, pas au trafic entrant sur le gateway lui-même.

```
Datacenter (HTTP) ──► [InternalGateway sidecar] ──mTLS──► [Service sidecar]
                          ^                                      ^
                      STRICT OK                             STRICT OK
                      (gateway est le point d'entrée)
```

### 7.6 Ordre de migration recommandé

```
1. Appliquer PERMISSIVE global (mesh-wide)
2. Valider que les métriques mTLS montent (connection_security_policy="mutual_tls")
3. Namespace par namespace :
   a. Observer métriques — trafic non-mTLS restant ?
   b. Identifier et corriger les sources non-mTLS
   c. Appliquer STRICT sur le namespace
   d. Surveiller 24h — erreurs 503 / taux de rejet ?
4. Une fois tous les namespaces en STRICT, supprimer la PeerAuthentication globale PERMISSIVE
```

---

## 8. Cert-manager et gestion des certificats

### 8.1 Certificats publics (ingress externe)

cert-manager émet et renouvelle les certificats TLS utilisés par l'IngressGateway pour terminer HTTPS/gRPC-TLS :

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ingress-tls
  namespace: istio-ingress
spec:
  secretName: ingress-tls-secret
  dnsNames:
    - "api.example.com"
    - "grpc.example.com"
  issuerRef:
    name: letsencrypt-prod         # Ou CA interne selon politique
    kind: ClusterIssuer
  renewBefore: 720h                # Renouvellement 30 jours avant expiration
```

Istio lit le secret via SDS et recharge Envoy **sans downtime**.

### 8.2 Certificats internes (gateway datacenter)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: internal-tls
  namespace: istio-internal
spec:
  secretName: internal-tls-secret
  dnsNames:
    - "*.internal.example.com"
  issuerRef:
    name: internal-ca-issuer       # CA interne — à définir
    kind: ClusterIssuer
```

### 8.3 CA Istio (SVIDs pour mTLS entre sidecars)

Istio issiod gère ses propres SVIDs SPIFFE. Configurer la CA racine via le secret `cacerts` :

```bash
kubectl create secret generic cacerts \
  -n istio-system \
  --from-file=ca-cert.pem \
  --from-file=ca-key.pem \
  --from-file=root-cert.pem \
  --from-file=cert-chain.pem
```

Si la décision de multi-cluster est Primary-Remote, un seul `cacerts` suffit (ingress-cluster). Si Multi-Primary, les deux clusters doivent avoir un `cacerts` signé par la même CA racine.

### 8.4 Rotation des SVIDs

| Paramètre | Valeur par défaut | Recommandation |
|---|---|---|
| Durée du SVID workload | 24h | 24h (acceptable) |
| Rotation proactive | 80% de la durée | Conserver |
| Rotation du secret `cacerts` | Manuelle | Planifier tous les 12 mois |

---

## 9. Observabilité

### 9.1 Métriques clés

| Métrique | Ce qu'elle indique |
|---|---|
| `istio_requests_total` | Taux de requêtes par service, code retour, source |
| `istio_request_duration_milliseconds` | Latence p50/p95/p99 par service |
| `connection_security_policy` | Proportion mTLS vs clair — essentiel pendant la migration |
| `pilot_xds_pushes` | Taux de push du control plane (santé istiod) |
| `pilot_proxy_convergence_time` | Délai de propagation de la config |
| `certmanager_certificate_expiration_timestamp_seconds` | Alerting expiration certificats |

**Requête pour suivre la progression mTLS :**

```promql
# Ratio trafic mTLS par namespace
sum(
  rate(istio_requests_total{connection_security_policy="mutual_tls"}[5m])
) by (destination_service_namespace)
/
sum(
  rate(istio_requests_total[5m])
) by (destination_service_namespace)
```

### 9.2 Alertes recommandées

| Alerte | Condition | Sévérité |
|---|---|---|
| Cert expiration imminente | `certmanager_certificate_expiration < now() + 7j` | Critical |
| istiod sous pression | `pilot_proxy_convergence_time` p99 > 5s | Warning |
| Latence est-ouest dégradée | `istio_request_duration_milliseconds` p99 > 10ms (même région) | Warning |
| Trafic non-mTLS post-STRICT | `connection_security_policy="none"` sur namespace STRICT | Critical |
| ExtAuthz injoignable | Taux d'erreur gRPC ExtAuthz > 0% | Critical |

### 9.3 Tracing distribué

Propager les en-têtes standard dans **tous les services applicatifs** (responsabilité des équipes produit) :

```
x-request-id
x-b3-traceid
x-b3-spanid
x-b3-sampled
```

```yaml
# meshConfig sur les deux clusters
meshConfig:
  enableTracing: true
  defaultConfig:
    tracing:
      zipkin:
        address: jaeger-collector.observability.svc:9411
      sampling: 10.0    # 10% en production, 100% en debug
```

Le service ExtAuthz doit également propager ces en-têtes pour que la trace soit complète de bout en bout.

### 9.4 Logs d'accès

```yaml
meshConfig:
  accessLogFile: /dev/stdout
  accessLogFormat: |
    {
      "timestamp": "%START_TIME%",
      "method": "%REQ(:METHOD)%",
      "path": "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%",
      "response_code": "%RESPONSE_CODE%",
      "duration_ms": "%DURATION%",
      "upstream_cluster": "%UPSTREAM_CLUSTER%",
      "connection_security_policy": "%CONNECTION_SECURITY_POLICY%",
      "request_id": "%REQ(X-REQUEST-ID)%"
    }
```

---

## 10. Phases de migration et plan de rollback

### Vue d'ensemble

```
Phase 0          Phase 1           Phase 2            Phase 3           Phase 4
Préparation      Shadow            Bascule            STRICT mTLS        Nettoyage
──────────       ───────           ──────────         ───────────        ──────────
Infra clusters   Dual-stack LB     100% Istio         Namespace par      Suppression
Istio install    10%→50%→90%       ExtAuthz enforce   namespace          Nginx
Cert-manager     JWT PERMISSIVE    Valider métriques  Valider 24h        Migration
ExtAuthz audit   Schema actif      GW interne live                       complète
GW interne prêt
```

---

### Phase 0 — Préparation infrastructure (Semaine 1–2)

**Tâches :**
- Provisionner `ingress-cluster` et `workload-cluster` sur Rancher
- Installer Istio sur les deux clusters (profil selon modèle multi-cluster choisi)
- Configurer `cacerts` et cert-manager sur les deux clusters
- Déployer le gateway est-ouest sur les deux clusters et valider port 15443
- Déployer le gateway interne sur workload-cluster, valider HTTP/HTTPS/gRPC depuis le datacenter
- Déployer ExtAuthz en **mode audit** (log uniquement, jamais de rejet)
- Appliquer `PeerAuthentication: PERMISSIVE` global sur les deux clusters
- Mettre en place Prometheus, Jaeger, Kiali

**Critère de sortie :** Le gateway interne répond aux requêtes datacenter. ExtAuthz démarre et reçoit les health checks gRPC. Métriques Istio visibles dans Prometheus.

**Rollback :** Aucun impact production — Nginx traite encore 100% du trafic.

---

### Phase 1 — Shadow / Bascule progressive (Semaine 3–5)

**Objectif :** Faire tourner Nginx et Istio en parallèle avec un split de trafic progressif.

**Approche :**
- Conserver le DNS actuel pointant vers le LB Nginx.
- Créer un second LB pointant vers l'IngressGateway Istio.
- Utiliser le LB externe (ou DNS pondéré) pour diviser :

```
Semaine 3 : 10% Istio / 90% Nginx
Semaine 4 : 50% Istio / 50% Nginx
Semaine 5 : 90% Istio / 10% Nginx
```

**Configuration :**
- `RequestAuthentication` RS512 actif — en mode PERMISSIVE (rejet JWT invalides uniquement)
- ExtAuthz toujours en mode audit
- Gateway interne actif pour les flux datacenter

**Checklist de validation :**
- [ ] Latence p99 Istio ≤ Nginx + 5ms
- [ ] Delta taux d'erreur < 0,1%
- [ ] Tokens JWT rejetés correctement (tester avec token expiré, mauvaise signature)
- [ ] Flux datacenter via gateway interne fonctionnels
- [ ] Traces présentes dans Jaeger pour les deux clusters

**Rollback :** Repositionner le poids LB à 100% Nginx. Aucun changement applicatif.

---

### Phase 2 — Bascule complète (Semaine 6)

**Prérequis :**
- Validation Phase 1 à 90% réussie sans incident critique
- Runbook validé par l'équipe on-call
- Fenêtre de maintenance approuvée

**Étapes :**
1. Basculer 100% du trafic vers Istio IngressGateway
2. Activer ExtAuthz en **mode enforce** (`statusOnError: DENY`)
3. Valider : smoke tests, moniteurs synthétiques, dashboards erreurs
4. Conserver Nginx en veille à 0% pendant 48h (rollback rapide disponible)
5. Après 48h sans incident : retirer Nginx du pool LB

**Rollback (dans les 48h) :**
- Repositionner LB vers Nginx (secondes)
- Nginx est encore actif et non modifié

**Rollback (après suppression Nginx) :**
- Runbook de re-provisioning Nginx (~30 min)
- RTO acceptable après la fenêtre de 48h

---

### Phase 3 — Migration STRICT mTLS (Semaine 7–8)

**Principe :** Namespace par namespace, après vérification des métriques.

Pour chaque namespace applicatif :

```bash
# 1. Vérifier le trafic non-mTLS résiduel
kubectl exec -n istio-system deploy/prometheus -- \
  promtool query instant 'http://localhost:9090' \
  'sum(istio_requests_total{destination_service_namespace="<NS>",connection_security_policy="none"}) by (source_workload)'

# 2. Si résultat == 0, appliquer STRICT
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: <NS>
spec:
  mtls:
    mode: STRICT
EOF

# 3. Surveiller 24h
```

**Rollback namespace :**
```bash
kubectl patch peerauthentication default -n <NS> \
  --type merge -p '{"spec":{"mtls":{"mode":"PERMISSIVE"}}}'
```

---

### Phase 4 — Nettoyage (Semaine 9)

**Tâches :**
- Supprimer le déploiement Nginx Ingress Controller et ses CRDs
- Supprimer les ressources `Ingress` legacy du workload-cluster
- Convertir tout objet `Ingress` restant en `VirtualService` + `Gateway` Istio
- Supprimer la `PeerAuthentication` PERMISSIVE globale (remplacée par les STRICT namespace)
- Connecter les logs ExtAuthz au SIEM
- Mise à jour de la documentation d'architecture

---

### Arbre de décision rollback

```
Incident détecté
    │
    ├─ Phase 0 : aucun impact prod → tear down clusters test
    │
    ├─ Phase 1 (< 90%) : LB 100% Nginx → investiguer
    │
    ├─ Phase 2 (< 48h) : LB 100% Nginx → investiguer
    │
    ├─ Phase 2 (> 48h, Nginx supprimé) : runbook re-provisioning Nginx, RTO 30 min
    │
    └─ Phase 3 (STRICT namespace) : patch PeerAuthentication → PERMISSIVE, RTO < 1 min
```

---

## 11. Décisions ouvertes

| # | Décision | Options | Propriétaire | Échéance |
|---|---|---|---|---|
| 1 | Modèle multi-cluster | Primary-Remote (istiod unique) vs Multi-Primary (istiod par cluster) | Architecte Plateforme | Avant Phase 0 |
| 2 | IdP JWT | IdP unique (même JWKS) vs IdP interne distinct | Équipe Sécurité | Avant Phase 1 |
| 3 | Backend CA racine | Vault PKI, step-ca, HSM offline | Équipe Sécurité | Avant Phase 0 |
| 4 | Infrastructure gateway interne | MetalLB + ClusterIP, ou LB Rancher natif | Équipe Plateforme | Phase 0 |
| 5 | Rancher vs GKE | Rester sur Rancher ou migrer cloud en parallèle | Direction Technique | Avant Phase 0 |
| 6 | Stockage specs OpenAPI | ConfigMap Git-backed, registre OCI, ou API control plane | Équipe Plateforme | Phase 1 |
| 7 | Backend observabilité | Auto-hébergé (Prometheus + Jaeger) ou managé | Équipe Plateforme | Phase 0 |

---

*Référence officielle : https://istio.io/latest/docs/setup/install/multicluster/*  
*Référence RequestAuthentication : https://istio.io/latest/docs/reference/config/security/request_authentication/*
