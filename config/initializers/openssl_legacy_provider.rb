# PDFs from insurers, banks and government bodies are routinely encrypted with
# RC4, and OpenSSL 3 keeps RC4 in a "legacy" provider that is not loaded by
# default. Without this, Origami raises `EVP_CipherInit_ex: unsupported` and
# PdfSafetyScanner refuses a perfectly readable document as damaged (D1).
#
# Loading a provider *adds* to the set in use rather than replacing the default
# one, so Rails' own AES-GCM credentials, cookies and Active Storage signing are
# unaffected. Verified: AES remains available after this line runs.
#
# The trade accepted in D1 is that RC4 and DES are now available to the whole
# process. Nothing in this app asks OpenSSL for either.
#
# The Dockerfile runs this same load at build time, so a base image without the
# legacy module fails the build rather than silently refusing every encrypted
# upload (D4).
OpenSSL::Provider.load("legacy")
