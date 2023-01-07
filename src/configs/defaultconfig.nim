const defaultConfig* = """
echo("Loading the default SAMI config")

color: true
log_level: "info"

extraction_output_handlers: ["stdout"]
injection_prev_sami_output_handlers: []
injection_output_handlers: []

key INSERTION_HOSTINFO {
    info, exitCode := system("uname -a")
    if exitCode == 0 {
      value: info
    }
}

outhook s3 {
  sink: "s3"
  if envExists("AWS_ACCESS_SECRET") {
    secret: env("AWS_ACCESS_SECRET")
  }
  else {
    secret: "No AWS secret provided.  Set the env variable AWS_ACCESS_SECRET"
  }
  if envExists("AWS_ACCESS_ID") {
    userid: env("AWS_ACCESS_ID")
  }
  else {
    userid: "No AWS access id provided.  Set the env variable AWS_ACCESS_ID"
  }
  if envExists("AWS_REGION") {
    region: env("AWS_REGION")
  }
  if envExists("AWS_S3_BUCKET_URI") {
    uri: env("AWS_S3_BUCKET_URI")
  }
  else {
    uri: "s3://example-bucket/example-object-path"
  }
}
"""
