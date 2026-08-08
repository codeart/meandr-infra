# The Glue Data Catalog database the archive is queried through.
#
# The database and nothing else. Its TABLES are provisioned by the
# application (`rake archive:provision`), because their columns are
# DERIVED from the Rails models — the same models the Archiver writes the
# Parquet from, which is what keeps reader and writer schema in step.
# Stating those columns here would mean maintaining them twice and
# learning about drift from a query that silently cannot see a new
# column.
#
# So this owns what is stable and knowable at plan time; the app owns
# what only it knows. The practical payoff is that no runtime identity
# needs glue:CreateDatabase, and a task role can be catalog-read-only.
resource "aws_glue_catalog_database" "this" {
  name        = var.name
  description = var.description
  tags        = var.tags
}
