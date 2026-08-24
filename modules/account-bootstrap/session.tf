# Session Manager starts /bin/sh, which reads no profile. The document name
# is fixed — preferences are read only from this exact name.
resource "aws_ssm_document" "session_shell" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager shell preferences"
    sessionType   = "Standard_Stream"
    inputs = {
      shellProfile = {
        linux = "bash -l"
      }
    }
  })

  tags = var.tags
}