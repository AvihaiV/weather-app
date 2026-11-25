module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.30.2"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # API reachable privately from the VPC, and publicly only from listed CIDRs (IAM auth still required).
  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.eks_public_access_cidrs

  # Control-plane audit trail: who did what in the cluster.
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  # The identity running `terraform apply` becomes cluster admin. Access is via EKS access entries, not aws-auth.
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    # CI can deploy only into the app namespace: no kube-system, no cluster-wide RBAC.
    github_deploy = {
      principal_arn = aws_iam_role.github_deploy.arn
      policy_associations = {
        edit = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = { type = "namespace", namespaces = [local.namespace] }
        }
      }
    }
  }

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      # Enforces Kubernetes NetworkPolicy without installing Calico/Cilium.
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    # Pod Identity: pods get short-lived AWS credentials per ServiceAccount. No access keys anywhere.
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_min_size

      # IMDSv2 only, hop limit 1: the IMDS token reply cannot cross the extra network hop of a normal
      # (pod-network) pod, so ordinary pods can't get the node role's credentials. NOT a full boundary:
      # hostNetwork pods and anything with node-level access (privileged pod, hostPath, container escape,
      # SSM/SSH) still reach IMDS. Those are blocked by Pod Security restricted in app namespaces, not by this.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }
}

# Role for the AWS Load Balancer Controller (installed with Helm in the K8s stage).
module "lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"
  # Scoped Checkov exceptions: apply ONLY to policy documents inside this pinned module (reviewed).
  # The attached one is AWS's published LB Controller policy: it must create/modify ALBs, target groups and
  # security groups whose ARNs don't exist yet, so "Resource: *" can't be narrowed; AWS limits writes with
  # elbv2.k8s.aws/cluster tag conditions. The module's other documents (appmesh, ebs_csi, velero...) are count = 0.
  # checkov:skip=CKV_AWS_356:AWS-published LB Controller policy, see comment above
  # checkov:skip=CKV_AWS_111:AWS-published LB Controller policy, see comment above
  # checkov:skip=CKV_AWS_109:AWS-published LB Controller policy, see comment above

  name                            = "${local.name}-lb-controller"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}
