##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Registers the built-in policy rules. Add new rules here.

import "."/[
  api,
  rules/certificates,
  rules/custom_check,
  rules/golden_images,
  rules/packages,
  rules/secrets,
]

proc loadPolicyRules*() =
  if hasPolicyRules():
    return
  loadGoldenImagesRule()
  loadCertificatesRule()
  loadSecretsRule()
  loadPackagesRule()
  loadCustomCheckRule()
