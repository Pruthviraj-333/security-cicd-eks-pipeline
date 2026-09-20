# terraform/argocd.tf
# ─────────────────────────────────────────────────────────────────────────────
# ArgoCD installation via Helm + initial Application configuration
#
# Installs ArgoCD and configures it to watch:
#   - microservices-demo/kubernetes-manifests/ (pilot services)
#   - Syncs from: github.com/Pruthviraj-333/security-cicd-eks-pipeline
#
# Security hardening:
#   - Server runs in insecure mode behind an internal ALB (TLS terminated at ALB)
#   - RBAC restricted: ArgoCD users get read-only by default
#   - Image updater uses IRSA (no registry credentials in secrets)
# ─────────────────────────────────────────────────────────────────────────────

# ── ArgoCD namespace ─────────────────────────────────────────────────────────
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace

    labels = {
      "app.kubernetes.io/name"       = "argocd"
      "pod-security.kubernetes.io/enforce" = "restricted"  # K8s Pod Security Standards
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }

  depends_on = [module.eks]
}

# ── ArgoCD Helm release ───────────────────────────────────────────────────────
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = kubernetes_namespace.argocd.metadata[0].name
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      global = {
        logging = {
          format = "json"
          level  = "info"
        }
      }

      server = {
        # Run in insecure mode — TLS terminated at ALB level
        insecure = true

        serviceAccount = {
          name = local.argocd_server_sa_name
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.argocd_server.arn
          }
        }

        # RBAC config — least privilege defaults
        rbacConfig = {
          "policy.default" = "role:readonly"
          "policy.csv"     = <<-RBAC
            p, role:admin, applications, *, */*, allow
            p, role:admin, clusters, get, *, allow
            p, role:admin, repositories, get, *, allow
            p, role:admin, repositories, create, *, allow
            p, role:admin, repositories, update, *, allow
            p, role:admin, repositories, delete, *, allow
            p, role:admin, logs, get, *, allow
            p, role:admin, exec, create, */*, allow
            g, pipeline-ci, role:admin
          RBAC
        }

        resources = {
          limits = {
            cpu    = "500m"
            memory = "256Mi"
          }
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }

      applicationSet = {
        resources = {
          limits   = { cpu = "200m", memory = "128Mi" }
          requests = { cpu = "50m",  memory = "64Mi" }
        }
      }

      controller = {
        serviceAccount = {
          name = local.argocd_sa_name
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.argocd_controller.arn
          }
        }

        resources = {
          limits   = { cpu = "1000m", memory = "1Gi" }
          requests = { cpu = "250m",  memory = "256Mi" }
        }

        # Metrics for Grafana (Stage 8)
        metrics = {
          enabled = true
          serviceMonitor = {
            enabled = true
          }
        }
      }

      repoServer = {
        resources = {
          limits   = { cpu = "500m", memory = "512Mi" }
          requests = { cpu = "100m", memory = "128Mi" }
        }
      }

      redis = {
        resources = {
          limits   = { cpu = "200m", memory = "128Mi" }
          requests = { cpu = "50m",  memory = "64Mi" }
        }
      }

      # HA mode (set to true for prod — requires 3 replicas)
      redis-ha = {
        enabled = false
      }

      # Notifications (Slack/email alerts for sync failures, etc.)
      notifications = {
        enabled = true
        resources = {
          limits   = { cpu = "100m", memory = "64Mi" }
          requests = { cpu = "25m",  memory = "32Mi" }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.argocd,
    aws_iam_role.argocd_controller,
    aws_iam_role.argocd_server,
  ]
}

# ── ArgoCD Application: pilot services (deployed via argocd-apps Helm chart) ──
# Deployed via Helm so that Terraform can plan cleanly before the cluster and
# CRDs exist (kubernetes_manifest requires a live API connection at plan time).
resource "helm_release" "argocd_app_pilot" {
  name       = "online-boutique-pilot-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "~> 2.0"
  namespace  = var.argocd_namespace

  values = [
    yamlencode({
      applications = {
        "online-boutique-pilot" = {
          namespace  = var.argocd_namespace
          project    = "default"
          finalizers = ["resources-finalizer.argocd.argoproj.io"]

          source = {
            repoURL        = "https://github.com/Pruthviraj-333/security-cicd-eks-pipeline.git"
            targetRevision = "HEAD"
            path           = "microservices-demo/kubernetes-manifests"
          }

          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "default"
          }

          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
            syncOptions = [
              "Validate=true",
              "CreateNamespace=false",
              "PrunePropagationPolicy=foreground",
              "PruneLast=true",
              "ApplyOutOfSyncOnly=true"
            ]
            retry = {
              limit = 5
              backoff = {
                duration    = "5s"
                factor      = 2
                maxDuration = "3m"
              }
            }
          }
        }
      }
    })
  ]

  depends_on = [helm_release.argocd]
}
