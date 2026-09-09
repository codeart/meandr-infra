# Session Manager shell preferences for THIS region.
#
# The name is fixed and load-bearing: Session Manager reads preferences
# only from `SSM-SessionManagerRunShell`, and falls back to a bare `sh`
# when it is absent rather than erroring.
#
# Regional, so it belongs to a region's stack even though it is otherwise
# an account-level concern. An account stack reaches a second region only
# through an explicit provider alias, so adding a region there is a hand
# edit that fails silently; here the region IS the directory.
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
