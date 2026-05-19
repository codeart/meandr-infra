terraform {
  backend "s3" {
    bucket         = "meandr-tfstate-shared"
    key            = "account-staging/terraform.tfstate"   # ← was staging-account/
    region         = "eu-central-1"
    dynamodb_table = "meandr-tfstate-locks"
    kms_key_id     = "arn:aws:kms:eu-central-1:303529433558:key/84863422-0293-4d86-8d9e-d3e5bc047648"
    encrypt        = true

    # State lives in Shared even though we manage Staging resources here.
    # Backend authenticates as meandr-shared; provider authenticates as meandr-staging.
    profile = "meandr-shared"
  }
}
