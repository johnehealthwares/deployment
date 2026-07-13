variable "aws_region" {
  default = "eu-west-1"
}

variable "allowed_ips" {
  type = list(string)

  default = [
    "0.0.0.0/0"
  ]
}

variable "bucket_name" {
  default = "rxsoft-postgres-backups-prod"
}

variable "deploy_mode" {
  description = "Deployment mode: dev or prod"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "prod"], var.deploy_mode)
    error_message = "Must be 'dev' or 'prod'."
  }
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "service_memory" {
  description = "Memory percentage per service (0 = exclude). Sum should be ≤ 80."
  type        = map(number)
  default = {
    mongodb             = 15
    mongo-init          = 2
    postgres            = 20
    rxsoft-backend      = 18
    rxsoft-lis-backend  = 0
    conversation-engine = 0
    healthcare-concepts = 0
    healthcare-interop  = 0
    rxsoft-identity     = 10
    rxsoft-admin        = 5
    ehealthwares        = 10
  }
}