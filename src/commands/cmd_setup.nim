import ../config, ../attestation, ../reporting, ../selfextract

proc runCmdSetup*() =
  let selfChalk = getSelfExtraction().getOrElse(nil)

  if selfChalk == nil:
    error("Platform does not support self-chalking.")
    return

  selfChalk.addToAllChalks()
  info("Ensuring cosign is present to setup attestation.")
  initAttestation()
  doReporting()
