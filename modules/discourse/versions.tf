terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.24"
      # The public zone lives in the Shared account; the caller passes a
      # provider for it as `aws.dns`.
      configuration_aliases = [aws.dns]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # The drain window between moving the record and destroying the box it
    # pointed at.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}
