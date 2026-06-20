terraform {
  backend "s3" {
    bucket         = "meandr-tfstate-shared"
    key            = "account-master/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "meandr-tfstate-locks"
    kms_key_id     = "arn:aws:kms:eu-central-1:303529433558:key/84863422-0293-4d86-8d9e-d3e5bc047648"
    encrypt        = true

    # State lives in Shared even though we manage Master resources here.
    # Backend authenticates as meandr-shared; provider authenticates as meandr-master.
    profile = "meandr-shared"
  }
}
