terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.24"
      # Empty on purpose: everything here is account-global. A resource
      # that is per-REGION belongs to a region's stack, where adding a
      # region adds it automatically — see modules/ssm-session-prefs.
      configuration_aliases = []
    }
  }
}
