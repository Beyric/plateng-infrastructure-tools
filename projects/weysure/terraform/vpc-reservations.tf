################################################################################
# Pod address blocks (Finding 45)
#
# With prefix delegation a node takes pod addresses in /28 blocks of 16. AWS only
# hands out a block that is completely free and aligned. Single addresses - a
# node's own IP, the EKS control plane's interfaces, RDS - are placed anywhere,
# and one of them makes all 16 addresses of its block unusable as a prefix.
#
# 2026-09-29: subnet 10.0.4.0/24 had 144 free addresses and no free block. A new
# node could not start a single pod (EC2: InsufficientCidrBlocks).
#
# A "prefix" reservation keeps single addresses out of a range. Addresses already
# in use inside it stay until their owner is replaced; nothing running is touched.
#
# Per private /24:   .0  - .63    single addresses (60 usable)
#                    .64 - .239   reserved for prefixes = 11 blocks = 176 pod addresses
#                    .240 - .255  single addresses (15 usable; .255 is AWS's)
#
# This is a repair, not the end state: a /24 is small for prefix delegation.
# Larger subnets for nodes are a follow-up (checklist: deferred follow-ups).
################################################################################

locals {
  # name => [newbits, netnum] for cidrsubnet() on a /24
  pod_prefix_ranges = {
    "64-127"  = [2, 1]  # .64/26
    "128-191" = [2, 2]  # .128/26
    "192-223" = [3, 6]  # .192/27
    "224-239" = [4, 14] # .224/28
  }

  pod_prefix_reservations = merge([
    for i, az in var.availability_zones : {
      for name, r in local.pod_prefix_ranges :
      "${az}-${name}" => {
        subnet_index = i
        cidr         = cidrsubnet(var.private_subnet_cidrs[i], r[0], r[1])
      }
    }
  ]...)
}

resource "aws_ec2_subnet_cidr_reservation" "pod_prefixes" {
  for_each = local.pod_prefix_reservations

  subnet_id        = module.vpc.private_subnets[each.value.subnet_index]
  cidr_block       = each.value.cidr
  reservation_type = "prefix"
  description      = "Pod /28 prefixes only (VPC CNI prefix delegation) - Finding 45"
}
