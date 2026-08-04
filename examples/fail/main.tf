# Non-compliant fixture. Every rule in policy/ should fire at least once here.
# Used by the self-test to prove the gates actually gate.

provider "aws" {
  region = "ap-southeast-2" # not in the approved region set
}

resource "aws_s3_bucket" "untagged" {
  bucket = "guardrails-fixture-untagged" # no tags at all
}

resource "aws_cloudwatch_log_group" "forever" {
  name = "/guardrails/forever" # no retention_in_days

  tags = {
    Project     = "guardrails-fixture"
    Environment = "dev"
    Owner       = "jordan"
    ManagedBy   = "terraform"
  }
}

resource "aws_security_group" "wide_open" {
  name   = "wide-open"
  vpc_id = "vpc-123456"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # ssh from the entire internet
  }

  tags = {
    Project     = "guardrails-fixture"
    Environment = "dev"
    Owner       = "jordan"
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_access_key" "static" {
  user = "service-account"
}

resource "aws_iam_policy" "admin" {
  name = "too-much"

  policy = <<-EOT
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": "*",
          "Resource": "*"
        }
      ]
    }
  EOT
}

resource "aws_nat_gateway" "a" {
  allocation_id = "eipalloc-a"
  subnet_id     = "subnet-a"

  tags = {
    Project     = "guardrails-fixture"
    Environment = "dev"
    Owner       = "jordan"
    ManagedBy   = "terraform"
  }
}

resource "aws_nat_gateway" "b" {
  allocation_id = "eipalloc-b"
  subnet_id     = "subnet-b"

  tags = {
    Project     = "guardrails-fixture"
    Environment = "dev"
    Owner       = "jordan"
    ManagedBy   = "terraform"
  }
}

resource "aws_instance" "oversized" {
  ami           = "ami-123456"
  instance_type = "m5.24xlarge"

  tags = {
    Project     = "guardrails-fixture"
    Environment = "dev"
    Owner       = "jordan"
    ManagedBy   = "terraform"
  }
}

# Module-based resources are invisible to HCL analysis, so provider
# default_tags must be complete. Here they are absent entirely.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.13.0"
  name    = "fixture"
}
