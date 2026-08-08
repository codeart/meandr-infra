variable "name" {
  description = "Database name in the Glue Data Catalog. Must match what the application derives — `Meandr::Athena.database` builds `meandr_<Rails env>`, so `meandr_development` / `meandr_staging` / `meandr_production`, NOT the 3-letter MEANDR_ENV."
  type        = string
}

variable "description" {
  description = "Free text shown in the Glue console. Worth naming the bucket the external tables sit over, since the database itself carries no location."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to the database."
  type        = map(string)
  default     = {}
}
