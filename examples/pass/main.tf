# Compliant fixture. The policy suite must report zero failures against this.

provider "aws" {
  region = "us-east-2"

  default_tags {
    tags = {
      Project   = "guardrails-fixture"
      ManagedBy = "terraform"
    }
  }
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "guardrails-fixture-artifacts"

  tags = {
    Environment = "dev"
    Owner       = "jordan"
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/guardrails/app"
  retention_in_days = 30

  tags = {
    Environment = "dev"
    Owner       = "jordan"
  }
}

resource "aws_security_group" "web" {
  name   = "web"
  vpc_id = "vpc-123456"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "dev"
    Owner       = "jordan"
  }
}

resource "aws_nat_gateway" "single" {
  allocation_id = "eipalloc-123456"
  subnet_id     = "subnet-123456"

  tags = {
    Environment = "dev"
    Owner       = "jordan"
  }
}
