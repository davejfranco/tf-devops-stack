terraform {
  backend "s3" {
    bucket = "444106639146-tf-state"
    key    = "terraform"
    region = "us-east-1"
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.67.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "personal"

  default_tags {
    tags = {
      Terraform   = "true"
      Environment = "youtube"
    }
  }
}
