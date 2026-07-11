terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_key_pair" "server" {
  key_name   = "rxsoft-key"
  public_key = file("${path.module}/ssh/id_rsa.pub")
}

resource "aws_security_group" "postgres" {
  name = "rxsoft-postgres"

  dynamic "ingress" {
    for_each = var.allowed_ips

    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = var.allowed_ips

    content {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8000
    to_port     = 8005
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_s3_bucket" "backups" {
  bucket = var.bucket_name
}

resource "aws_iam_role" "ec2_role" {
  name = "rxsoft-postgres-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Effect = "Allow"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "s3" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_instance_profile" "profile" {
  name = "rxsoft-profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_instance" "postgres" {

  ami           = "ami-0d64bb532e0502c46" # Ubuntu 24.04 eu-west-1
  instance_type = var.instance_type

  key_name = aws_key_pair.server.key_name

  iam_instance_profile = aws_iam_instance_profile.profile.name

  vpc_security_group_ids = [
    aws_security_group.postgres.id
  ]

  root_block_device {
    volume_size = 30
    encrypted   = true
    volume_type = "gp3"
  }

  user_data = replace(
    replace(
      replace(
        replace(file("cloud-init.sh"),
          "__SERVICE_MEMORY__",
          join("\n", [for svc, pct in var.service_memory : "${svc}=${pct}"])
        ),
        "__PROFILE_FLAGS__",
        join(" ", [for svc, pct in var.service_memory : "--profile ${svc}" if pct > 0])
      ),
      "DEPLOY_MODE=prod",
      "DEPLOY_MODE=${var.deploy_mode}"
    ),
    "__BACKUP_ENV__",
    trimspace(file("${path.module}/.env"))
  )

  tags = {
    Name = "rxsoft-postgres"
  }
}

resource "aws_eip" "postgres" {
  domain = "vpc"

  instance = aws_instance.postgres.id
}

output "public_ip" {
  value = aws_eip.postgres.public_ip
}