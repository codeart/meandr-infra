# Session Manager shell preferences for THIS region.
#
# The name is fixed and load-bearing: Session Manager reads preferences
# only from `SSM-SessionManagerRunShell`, and falls back to a bare `sh`
# when it is absent rather than erroring.
#
# Regional, so it belongs to a region's stack even though it is otherwise
# an account-level concern. It lived in account-bootstrap until 2026-09-08,
# where one document was created per account's DEFAULT provider — which
# left staging configured in eu-central-1 only and production in us-east-1
# only, for a year, invisibly. A region stack cannot make that mistake:
# adding a region means adding a directory, and the document comes with it.
#
# `bash -l` rather than the AWS default, so a session reads /etc/profile
# and lands on a prompt carrying the hostname set at boot.

resource "aws_ssm_document" "shell" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager shell preferences"
    sessionType   = "Standard_Stream"
    inputs = {
      shellProfile = {
        linux = var.linux_shell
      }
    }
  })

  tags = var.tags
}
