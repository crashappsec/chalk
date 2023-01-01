const defaultConfig = """
color: true
log_level: "info"

echo("Loading default SAMI config.")

extraction_output_handlers: ["stdout"]
injection_prev_sami_output_handlers: []
injection_output_handlers: []

output s3 {
  if envExists("AWS_ACCESS_SECRET") {
    secret: env("AWS_ACCESS_SECRET")
  }
  if envExists("AWS_ACCESS_ID") {
    userid: env("AWS_ACCESS_ID")
  }
  if envExists("AWS_REGION") {
    region: env("AWS_REGION")
  }
  if envExists("AWS_S3_BUCKET_URI") {
    dst_uri: env("AWS_S3_BUCKET_URI")
  }
}
"""
