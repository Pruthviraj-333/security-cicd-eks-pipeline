# terraform/monitoring.tf
# ─────────────────────────────────────────────────────────────────────────────
# Monitoring stack: Prometheus + Grafana + Alertmanager + Loki
#
# Stack: kube-prometheus-stack (Helm) + Grafana Loki (Helm)
# Namespace: monitoring
#
# Grafana datasources:
#   - Prometheus (cluster metrics)
#   - Loki (logs — pipeline scans + EKS control plane)
#   - CloudWatch (AWS metrics via IRSA — drift detection, scan counts)
#
# Dashboards provisioned:
#   - Security Pipeline Overview (Stages 1–7 scan results)
#   - Drift Detection (Stage 7 CloudWatch metrics)
#   - ArgoCD GitOps status
#   - EKS cluster health
# ─────────────────────────────────────────────────────────────────────────────

# ── Monitoring namespace ──────────────────────────────────────────────────────
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.monitoring_namespace
    labels = {
      "app.kubernetes.io/name"             = "monitoring"
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }
  depends_on = [module.eks]
}

# ── kube-prometheus-stack (Prometheus + Grafana + Alertmanager) ───────────────
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "67.9.0"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      # ── Grafana ────────────────────────────────────────────────────────────
      grafana = {
        enabled       = true
        adminPassword = ""   # Set via grafana.adminPassword secret — see docs

        serviceAccount = {
          name = local.grafana_sa_name
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.grafana.arn
          }
        }

        # Persistence (use EBS PVC for dashboards + data)
        persistence = {
          enabled          = true
          storageClassName = "gp3-encrypted"
          size             = "10Gi"
        }

        resources = {
          limits   = { cpu = "500m", memory = "512Mi" }
          requests = { cpu = "100m", memory = "128Mi" }
        }

        # ── Datasources ──────────────────────────────────────────────────────
        additionalDataSources = [
          {
            name   = "Loki"
            type   = "loki"
            url    = "http://loki-gateway.${var.monitoring_namespace}.svc.cluster.local"
            access = "proxy"
            jsonData = {
              maxLines    = 1000
              derivedFields = []
            }
          },
          {
            name   = "CloudWatch"
            type   = "cloudwatch"
            access = "proxy"
            jsonData = {
              authType      = "default"   # Uses IRSA (Grafana SA has CW read role)
              defaultRegion = var.aws_region
            }
          }
        ]

        # ── Dashboard provisioning ────────────────────────────────────────────
        dashboardProviders = {
          "dashboardproviders.yaml" = {
            apiVersion = 1
            providers = [
              {
                name            = "security-pipeline"
                orgId           = 1
                folder          = "Security Pipeline"
                type            = "file"
                disableDeletion = false
                editable        = true
                options         = { path = "/var/lib/grafana/dashboards/security-pipeline" }
              },
              {
                name            = "gitops"
                orgId           = 1
                folder          = "GitOps"
                type            = "file"
                disableDeletion = false
                editable        = true
                options         = { path = "/var/lib/grafana/dashboards/gitops" }
              }
            ]
          }
        }

        # Load dashboards from ConfigMaps (see below)
        dashboardsConfigMaps = {
          security-pipeline = "grafana-dashboard-security-pipeline"
          gitops            = "grafana-dashboard-gitops"
        }

        # Grafana INI settings
        grafana_ini = {
          server = {
            root_url = "%(protocol)s://%(domain)s/grafana"
          }
          auth = {
            disable_login_form = false
          }
          security = {
            allow_embedding = false
            cookie_secure   = true
            strict_transport_security = true
          }
          analytics = {
            reporting_enabled = false
            check_for_updates = false
          }
        }
      }

      # ── Prometheus ──────────────────────────────────────────────────────────
      prometheus = {
        prometheusSpec = {
          retention             = "15d"
          retentionSize         = "10GB"
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3-encrypted"
                accessModes      = ["ReadWriteOnce"]
                resources        = { requests = { storage = "20Gi" } }
              }
            }
          }

          resources = {
            limits   = { cpu = "1000m", memory = "2Gi" }
            requests = { cpu = "200m",  memory = "512Mi" }
          }

          # Scrape ArgoCD metrics
          additionalScrapeConfigs = [
            {
              job_name        = "argocd"
              scrape_interval = "30s"
              static_configs  = [{ targets = ["argocd-metrics.${var.argocd_namespace}.svc.cluster.local:8082"] }]
            }
          ]
        }
      }

      # ── Alertmanager ────────────────────────────────────────────────────────
      alertmanager = {
        alertmanagerSpec = {
          resources = {
            limits   = { cpu = "100m", memory = "128Mi" }
            requests = { cpu = "50m",  memory = "64Mi" }
          }
        }
      }

      # ── Node exporter ────────────────────────────────────────────────────────
      nodeExporter = {
        enabled = true
      }

      # ── Kube-state-metrics ────────────────────────────────────────────────────
      kubeStateMetrics = {
        enabled = true
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.monitoring,
    aws_iam_role.grafana,
    helm_release.aws_load_balancer_controller,
  ]
}

# ── Loki (log aggregation) ────────────────────────────────────────────────────
resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = "6.25.0"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      loki = {
        commonConfig = {
          replication_factor = 1   # Single replica for dev (increase for prod)
        }
        storage = {
          type = "filesystem"   # Use S3 for prod (switch to s3 + IRSA)
        }
        schemaConfig = {
          configs = [{
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "filesystem"
            schema       = "v13"
            index = {
              prefix = "index_"
              period = "24h"
            }
          }]
        }
        limits_config = {
          retention_period = "744h"   # 31 days
        }
      }

      deploymentMode = "SingleBinary"

      singleBinary = {
        replicas = 1
        resources = {
          limits   = { cpu = "500m", memory = "512Mi" }
          requests = { cpu = "100m", memory = "128Mi" }
        }
        persistence = {
          enabled          = true
          storageClass     = "gp3-encrypted"
          size             = "20Gi"
        }
      }

      # Promtail scrapes pod logs and ships to Loki
      gateway = {
        enabled = true
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# ── Promtail (ships pod logs → Loki) ─────────────────────────────────────────
resource "helm_release" "promtail" {
  name             = "promtail"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "promtail"
  version          = "6.16.6"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      config = {
        lokiAddress = "http://loki-gateway.${var.monitoring_namespace}.svc.cluster.local/loki/api/v1/push"
      }
      resources = {
        limits   = { cpu = "200m", memory = "128Mi" }
        requests = { cpu = "50m",  memory = "64Mi" }
      }
    })
  ]

  depends_on = [helm_release.loki]
}

# ── StorageClass: gp3-encrypted (for Prometheus + Grafana PVCs) ──────────────
resource "kubernetes_storage_class" "gp3_encrypted" {
  metadata {
    name = "gp3-encrypted"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = aws_kms_key.eks.arn
    fsType    = "ext4"
    iops      = "3000"
    throughput = "125"
  }

  depends_on = [module.eks]
}

# ── Grafana Dashboard: Security Pipeline ─────────────────────────────────────
resource "kubernetes_config_map" "grafana_dashboard_security" {
  metadata {
    name      = "grafana-dashboard-security-pipeline"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      "grafana_dashboard" = "1"
    }
  }

  data = {
    "security-pipeline.json" = jsonencode({
      title       = "Security Pipeline Overview"
      uid         = "security-pipeline-v1"
      description = "Aggregated view of all 8 security stages scan results"
      tags        = ["security", "pipeline", "cicd"]
      timezone    = "utc"
      refresh     = "5m"
      time        = { from = "now-24h", to = "now" }

      panels = [
        # Row: Pipeline Health
        {
          type       = "stat"
          title      = "Pipeline Runs (24h)"
          id         = 1
          gridPos    = { x = 0, y = 0, w = 4, h = 4 }
          datasource = "CloudWatch"
          targets = [{
            namespace  = "SecurityCICD/PipelineMetrics"
            metricName = "PipelineRuns"
            statistics = ["Sum"]
            period     = "86400"
          }]
        },
        {
          type       = "stat"
          title      = "Drift Detected"
          id         = 2
          gridPos    = { x = 4, y = 0, w = 4, h = 4 }
          datasource = "CloudWatch"
          fieldConfig = {
            defaults = {
              thresholds = {
                steps = [
                  { color = "green", value = 0 },
                  { color = "red",   value = 1 }
                ]
              }
            }
          }
          targets = [{
            namespace  = "SecurityCICD/DriftDetection"
            metricName = "DriftDetected"
            dimensions = { Cluster = "${local.cluster_name}" }
            statistics = ["Maximum"]
            period     = "300"
          }]
        },
        {
          type       = "stat"
          title      = "ArgoCD Sync Status"
          id         = 3
          gridPos    = { x = 8, y = 0, w = 4, h = 4 }
          datasource = "CloudWatch"
          fieldConfig = {
            defaults = {
              mappings = [
                { type = "value", options = { "0" = { text = "Out of Sync", color = "red" } } },
                { type = "value", options = { "1" = { text = "Synced",      color = "green" } } }
              ]
            }
          }
          targets = [{
            namespace  = "SecurityCICD/DriftDetection"
            metricName = "ArgoCDSyncStatus"
            dimensions = { App = "online-boutique-pilot" }
            statistics = ["Average"]
            period     = "300"
          }]
        },
        # Row: Scan Results (Loki logs)
        {
          type       = "logs"
          title      = "Recent Secret Scan Findings (Stage 1)"
          id         = 10
          gridPos    = { x = 0, y = 5, w = 24, h = 6 }
          datasource = "Loki"
          targets = [{
            expr = "{job=\"github-actions\"} |= \"gitleaks\" |= \"FINDING\""
          }]
        },
        {
          type       = "logs"
          title      = "Recent SAST Findings (Stage 2)"
          id         = 11
          gridPos    = { x = 0, y = 11, w = 24, h = 6 }
          datasource = "Loki"
          targets = [{
            expr = "{job=\"github-actions\"} |= \"gosec\" |~ \"HIGH|CRITICAL\""
          }]
        }
      ]
    })
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# ── Grafana Dashboard: GitOps / Drift ────────────────────────────────────────
resource "kubernetes_config_map" "grafana_dashboard_gitops" {
  metadata {
    name      = "grafana-dashboard-gitops"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      "grafana_dashboard" = "1"
    }
  }

  data = {
    "gitops.json" = jsonencode({
      title       = "GitOps & Drift Detection"
      uid         = "gitops-drift-v1"
      description = "ArgoCD sync status and cluster drift metrics"
      tags        = ["gitops", "argocd", "drift"]
      timezone    = "utc"
      refresh     = "1m"
      time        = { from = "now-1h", to = "now" }

      panels = [
        {
          type    = "timeseries"
          title   = "Cluster Drift Over Time"
          id      = 1
          gridPos = { x = 0, y = 0, w = 12, h = 8 }
          datasource = "CloudWatch"
          fieldConfig = {
            defaults = {
              color = { mode = "thresholds" }
              thresholds = {
                steps = [
                  { color = "green", value = 0 },
                  { color = "red",   value = 1 }
                ]
              }
            }
          }
          targets = [{
            namespace  = "SecurityCICD/DriftDetection"
            metricName = "DriftDetected"
            dimensions = { Cluster = "${local.cluster_name}" }
            statistics = ["Maximum"]
            period     = "300"
          }]
        },
        {
          type    = "timeseries"
          title   = "ArgoCD Health & Sync Status"
          id      = 2
          gridPos = { x = 12, y = 0, w = 12, h = 8 }
          datasource = "CloudWatch"
          targets = [
            {
              alias      = "Sync (1=Synced)"
              namespace  = "SecurityCICD/DriftDetection"
              metricName = "ArgoCDSyncStatus"
              dimensions = { App = "online-boutique-pilot" }
              statistics = ["Average"]
              period     = "60"
            },
            {
              alias      = "Health (1=Healthy)"
              namespace  = "SecurityCICD/DriftDetection"
              metricName = "ArgoCDHealthStatus"
              dimensions = { App = "online-boutique-pilot" }
              statistics = ["Average"]
              period     = "60"
            }
          ]
        }
      ]
    })
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# ── CloudWatch Alarm: Drift detected ─────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "drift_detected" {
  alarm_name          = "${local.name_prefix}-drift-detected"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "DriftDetected"
  namespace           = "SecurityCICD/DriftDetection"
  period              = 300
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "EKS cluster state has drifted from GitOps source of truth"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Cluster = local.cluster_name
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-drift-detected-alarm"
  })
}

# ── CloudWatch Alarm: ArgoCD out of sync ─────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "argocd_out_of_sync" {
  alarm_name          = "${local.name_prefix}-argocd-out-of-sync"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ArgoCDSyncStatus"
  namespace           = "SecurityCICD/DriftDetection"
  period              = 300
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "ArgoCD application is out of sync for more than 10 minutes"
  treat_missing_data  = "ignore"   # Ignore when cluster is down (don't false-alarm)

  dimensions = {
    App = "online-boutique-pilot"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-argocd-out-of-sync-alarm"
  })
}

# ── Output monitoring endpoints ───────────────────────────────────────────────
output "grafana_port_forward_command" {
  description = "Port-forward Grafana UI"
  value       = "kubectl port-forward svc/kube-prometheus-stack-grafana -n ${var.monitoring_namespace} 3000:80"
}

output "prometheus_port_forward_command" {
  description = "Port-forward Prometheus UI"
  value       = "kubectl port-forward svc/kube-prometheus-stack-prometheus -n ${var.monitoring_namespace} 9090:9090"
}
