locals {
  stack_name = "tf-devops-stack"
  network = {
    cidr = "10.0.0.0/16"
  }

}
### Datasources
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "this" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.13.0"

  name = "${local.stack_name}-vpc" // local.stack_name
  cidr = local.network.cidr

  azs             = slice(data.aws_availability_zones.this.names, 0, 3) // data.aws_availability_zones.this.names 
  private_subnets = [for i in range(3) : cidrsubnet(local.network.cidr, 8, i)]
  public_subnets  = [for i in range(3, 6) : cidrsubnet(local.network.cidr, 8, i)]

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Name = "${local.stack_name}-vpc"
  }
}


module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${local.stack_name}-cluster"
  cluster_version = "1.30"

  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]
  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.public_subnets

  eks_managed_node_groups = {
    devops = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]

      min_size     = 1
      max_size     = 5
      desired_size = 2
    }
  }

  # Cluster access entry
  # To add the current caller identity as an administrator
  enable_cluster_creator_admin_permissions = true

  access_entries = {}

  tags = {
    Name = "${local.stack_name}-cluster"
  }
}

## Cluster Components
### cert-manager
resource "helm_release" "cert_manager" {
  name = "cert-manager"

  namespace        = "cert-manager"
  chart            = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io/"

  set {
    name  = "installCRDs"
    value = "true"
  }
  depends_on = [module.eks]
}

### external-secrets
### IAM Role
module "external_secrets" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  role_name = "${local.stack_name}-external-secrets"

  attach_external_secrets_policy = true

  oidc_providers = {
    one = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "helm_release" "external_secrets" {
  name = "external-secrets"

  namespace        = "external-secrets"
  chart            = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io/"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets.iam_role_arn
  }

  depends_on = [
    module.eks,
    module.external_secrets
  ]
}

resource "kubectl_manifest" "cluster_store" {
  server_side_apply = true
  apply_only        = true
  force_conflicts   = true
  yaml_body         = <<-YAML
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
  YAML

  depends_on = [helm_release.external_secrets]
}

resource "aws_secretsmanager_secret" "github_token" {
  name                    = "${local.stack_name}-gha-token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "github_token" {
  secret_id = aws_secretsmanager_secret.github_token.id
  secret_string = jsonencode({
    github_token = var.github_token
    }
  )

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "kubectl_manifest" "arc_secret" {
  server_side_apply = true
  apply_only        = true
  force_conflicts   = true
  yaml_body         = <<-YAML
--- 
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: "controller-manager"
  namespace: runner-system
spec:
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  refreshInterval: "1h"
  target:
    name: controller-manager
    creationPolicy: Owner
  data:
  - secretKey: github_token
    remoteRef:
      key: "${local.stack_name}-gha-token"
      property: github_token

  YAML
  depends_on        = [helm_release.external_secrets]
}

resource "helm_release" "actions_runner" {
  name = "actions-runner-controller"

  namespace        = "runner-system"
  chart            = "actions-runner-controller"
  create_namespace = true
  upgrade_install  = true
  repository       = "https://actions-runner-controller.github.io/actions-runner-controller"

  depends_on = [
    module.eks,
    helm_release.cert_manager,
    kubectl_manifest.cluster_store
  ]
}

resource "kubectl_manifest" "runner_deployment" {
  server_side_apply = true
  apply_only        = true
  force_conflicts   = true
  yaml_body         = <<-YAML
---
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: runner
  namespace: runner-system
spec:
  replicas: 1
  template:
    spec:
      repository: davejfranco/tf-devops-stack
      labels:
        - youtube
        - demo
  YAML

  depends_on = [helm_release.actions_runner]
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

module "iam_github_oidc_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-role"

  name = "${local.stack_name}-gha-role"

  # This should be updated to suit your organization, repository, references/branches, etc.
  subjects = [
    "repo:davejfranco/tf-devops-stack:*"
  ]

  policies = {
    admin = "arn:aws:iam::aws:policy/AdministratorAccess"
  }
}

resource "aws_eks_access_entry" "github" {
  cluster_name      = module.eks.cluster_name
  principal_arn     = module.iam_github_oidc_role.arn
  kubernetes_groups = []
  type              = "STANDARD"
}

resource "aws_eks_access_policy_association" "github" {
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = module.iam_github_oidc_role.arn

  access_scope {
    type = "cluster"
  }
}
















































