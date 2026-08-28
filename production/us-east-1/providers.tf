provider "aws" {
  region  = local.region
  profile = local.aws_profile
}

# Global Accelerator's control plane exists ONLY in us-west-2, whatever
# region the endpoints live in. Nothing about the accelerator runs there.
provider "aws" {
  alias   = "usw2"
  region  = "us-west-2"
  profile = local.aws_profile
}

# The public zones live in the Shared account — ACM DNS validation and the
# public hostname records.
provider "aws" {
  alias   = "shared"
  region  = "eu-central-1"
  profile = "meandr-shared"
}
