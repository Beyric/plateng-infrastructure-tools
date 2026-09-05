variable "region" {
  description = "AWS region. Baked into every resource ARN — changing it means rebuilding (ADR-002)."
  type        = string
  default     = "us-east-1"
}

variable "organisation" {
  description = "Owns the cluster and the AWS account. Products live inside it as namespaces (ADR-018)."
  type        = string
  default     = "beyric"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "project" {
  description = "Scopes product-specific resources only - ECR repositories, namespaces, Vault KV paths.\nNever the cluster: see ADR-018."
  type        = string
  default     = "weysure"
}

variable "vpc_cidr" {
  description = "Cannot be changed after creation without recreating the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Worker nodes live here only. Nothing in the cluster is directly internet-reachable."
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "system_node_instance_type" {
  description = "Fixed-performance, not burstable. t3 throttles to 20-30% of a vCPU once credits run out, which presents as unexplained slowness rather than an error (ADR-003)."
  type        = string
  default     = "m6i.large"
}

variable "system_node_min" {
  type    = number
  default = 1
}

variable "system_node_max" {
  description = "Karpenter provisions everything else; this group only hosts Karpenter itself and the control-plane-like platform components."
  type        = number
  default     = 2
}

variable "system_node_desired" {
  description = "Two, since Phase 6. One m6i.large reached 89% CPU reserved with Vault, Argo CD, Karpenter, CoreDNS and the EBS CSI controllers, and the Jenkins controller could not schedule. Two also means Karpenter and Argo CD survive the loss of a node (ADR-012)."
  type        = number
  default     = 2
}

variable "db_instance_class" {
  description = "Graviton, single-AZ. Multi-AZ doubles this; revisit at the first paying-customer SLA (ADR-004)."
  type        = string
  default     = "db.t4g.micro"
}
