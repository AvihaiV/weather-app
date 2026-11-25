# Local / CI environment: everything the app needs, on a kind cluster, provisioned by Terraform.
# Same Helm chart as AWS (deploy/helm/weather); only the values file differs.
terraform {
  required_version = ">= 1.10"
  required_providers {
    kind       = { source = "tehcyx/kind", version = "0.13.0" }
    helm       = { source = "hashicorp/helm", version = "3.3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "3.5.0" }
    random     = { source = "hashicorp/random", version = "3.9.1" }
  }
  # Local state on purpose: this environment is disposable. State holds the generated DB passwords: never commit it.
}

variable "cluster_name" {
  type    = string
  default = "weather"
}

variable "host_port" {
  type        = number
  default     = 8088
  description = "Port on 127.0.0.1 where the UI is served"
}

variable "images" {
  type        = object({ backend = string, frontend = string })
  description = "Image references already present in the local Docker daemon (built locally or pulled+verified in CI)"
}

variable "db_instances" {
  type    = number
  default = 3
}

variable "monitoring_enabled" {
  type    = bool
  default = true
}

variable "grafana_anonymous" {
  type        = bool
  default     = false
  description = "Demo only: let anyone with the URL view dashboards (read-only Viewer role, no admin)"
}

# ---------------- Cluster ----------------
resource "kind_cluster" "this" {
  name           = var.cluster_name
  node_image     = "kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"
  wait_for_ready = true
  # Write the kubeconfig (admin private key!) outside the repo, never next to the code.
  kubeconfig_path = pathexpand("~/.kube/kind-${var.cluster_name}")

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
      # Only the UI NodePort is published, and only on localhost.
      extra_port_mappings {
        container_port = 30080
        host_port      = var.host_port
        listen_address = "127.0.0.1"
      }
    }
    # Two workers in two fake "zones": lets topology spread / anti-affinity behave like multi-AZ.
    node {
      role   = "worker"
      labels = { "topology.kubernetes.io/zone" = "zone-a" }
    }
    node {
      role   = "worker"
      labels = { "topology.kubernetes.io/zone" = "zone-b" }
    }
  }
}

provider "kubernetes" {
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
}

provider "helm" {
  kubernetes = {
    host                   = kind_cluster.this.endpoint
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  }
}

# kind nodes cannot pull from the host's Docker: copy the images in. Re-runs when the image refs change.
resource "terraform_data" "load_images" {
  triggers_replace = [var.images.backend, var.images.frontend, kind_cluster.this.id]
  provisioner "local-exec" {
    command = "kind load docker-image --name ${var.cluster_name} ${var.images.backend} ${var.images.frontend}"
  }
}

# ---------------- Namespaces (Pod Security Admission) ----------------
locals {
  namespaces = {
    weather     = "restricted" # app: strictest standard, enforced
    weather-db  = "restricted"
    cnpg-system = "restricted"
    monitoring  = "baseline" # Prometheus stack needs a few baseline-level permissions
  }
}

resource "kubernetes_namespace_v1" "this" {
  for_each = local.namespaces
  metadata {
    name = each.key
    labels = {
      "pod-security.kubernetes.io/enforce" = each.value
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# ---------------- DB credentials (generated, never in git) ----------------
locals {
  db_users = { api = "weather_api", collector = "weather_collector", migrate = "weather_migrate" }
}

resource "random_password" "db" {
  for_each = local.db_users
  length   = 32
  special  = false
}

# CloudNativePG reads role passwords from basic-auth secrets in the DB namespace.
resource "kubernetes_secret_v1" "db_role" {
  for_each = local.db_users
  metadata {
    name      = "weather-${each.key}-db"
    namespace = kubernetes_namespace_v1.this["weather-db"].metadata[0].name
  }
  type = "kubernetes.io/basic-auth"
  data = { username = each.value, password = random_password.db[each.key].result }
}

# Each app workload gets only its own password.
resource "kubernetes_secret_v1" "app_db" {
  for_each = local.db_users
  metadata {
    name      = "weather-${each.key}-db"
    namespace = kubernetes_namespace_v1.this["weather"].metadata[0].name
  }
  data = { password = random_password.db[each.key].result }
}

# ---------------- Platform ----------------
# The Helm provider only diffs chart version + values, not files inside a local chart.
# Hashing every file makes any template/dashboard edit trigger an upgrade.
locals {
  app_chart      = "${path.module}/../../deploy/helm/weather"
  db_chart       = "${path.module}/charts/weather-db"
  app_chart_hash = sha1(join("", [for f in sort(fileset(local.app_chart, "**")) : filesha1("${local.app_chart}/${f}")]))
  db_chart_hash  = sha1(join("", [for f in sort(fileset(local.db_chart, "**")) : filesha1("${local.db_chart}/${f}")]))
}
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.14.0"
  namespace  = "kube-system"
  # kind-only: kubelets use self-signed certs. Never set this on a real cluster.
  set = [{ name = "args[0]", value = "--kubelet-insecure-tls" }]
}

resource "helm_release" "cnpg" {
  name       = "cnpg"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = "0.29.2"
  namespace  = kubernetes_namespace_v1.this["cnpg-system"].metadata[0].name
  wait       = true
}

resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "helm_release" "monitoring" {
  count      = var.monitoring_enabled ? 1 : 0
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "93.11.0"
  namespace  = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  timeout    = 900 # first install pulls many images
  values = [
    file("${path.module}/monitoring-values.yaml"),
    # Demo only: read-only anonymous viewers (no admin password is ever printed or shared), and the
    # ~20 preloaded Kubernetes dashboards are not loaded, so the public sees only the 4 Weather dashboards.
    yamlencode({ grafana = {
      "grafana.ini"            = { "auth.anonymous" = { enabled = var.grafana_anonymous, org_role = "Viewer" } }
      defaultDashboardsEnabled = !var.grafana_anonymous
    } }),
  ]
  set_sensitive = [{ name = "grafana.adminPassword", value = random_password.grafana.result }]
}

resource "helm_release" "db" {
  name      = "weather-db"
  chart     = "${path.module}/charts/weather-db"
  namespace = kubernetes_namespace_v1.this["weather-db"].metadata[0].name
  set = [
    { name = "instances", value = tostring(var.db_instances) },
    { name = "monitoring", value = tostring(var.monitoring_enabled) },
    { name = "chartHash", value = local.db_chart_hash },
  ]
  depends_on = [helm_release.cnpg, kubernetes_secret_v1.db_role, helm_release.monitoring]
}

# Wait until the database actually accepts connections before deploying the app.
resource "terraform_data" "db_ready" {
  triggers_replace = [helm_release.db.id]
  provisioner "local-exec" {
    command = "kubectl --kubeconfig ${kind_cluster.this.kubeconfig_path} -n weather-db wait cluster/weather-db --for=condition=Ready --timeout=600s"
  }
}

resource "helm_release" "app" {
  name      = "weather"
  chart     = local.app_chart
  namespace = kubernetes_namespace_v1.this["weather"].metadata[0].name
  values    = [file("${path.module}/../../deploy/helm/weather/values-local.yaml")]
  set = [
    { name = "images.backend", value = var.images.backend },
    { name = "images.frontend", value = var.images.frontend },
    { name = "monitoring.enabled", value = tostring(var.monitoring_enabled) },
    { name = "chartHash", value = local.app_chart_hash },
  ]
  atomic     = true # failed upgrade (e.g. migration error) rolls back automatically
  timeout    = 300
  depends_on = [terraform_data.db_ready, terraform_data.load_images, kubernetes_secret_v1.app_db, helm_release.monitoring, helm_release.metrics_server]
}

output "ui_url" { value = "http://127.0.0.1:${var.host_port}" }
output "grafana" { value = "KUBECONFIG=~/.kube/kind-${var.cluster_name} kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80  (user admin, password: terraform output -raw grafana_password)" }
output "grafana_password" {
  value     = random_password.grafana.result
  sensitive = true
}
