# What each structural signal in a PDF means, in one enumerable place (R2.1).
#
# The hard part of this feature is classification, not detection. Scanning a
# genuine UnitedHealthcare policy turns up an embedded file (C2PA "Content
# Credentials" provenance signing) and ten external links (nyc.gov, hhs.gov,
# mailto:, tel:) — all entirely legitimate. A scanner that blocked on either
# would reject the most representative real document we have, so links and
# ordinary attachments are surfaced to the reader rather than used to refuse.
#
# What is blocked is content that asks a PDF viewer to *execute* something.
class PdfSafetyPolicy
  BLOCK = :block
  NOTE  = :note

  # Extensions whose whole purpose is to be run. An embedded file with one of
  # these is not a document someone attached for reference.
  EXECUTABLE_EXTENSIONS = %w[
    exe com scr bat cmd msi dll app pkg dmg
    sh bash zsh command
    js vbs vbe wsf ps1 jar py rb pl php
  ].freeze

  SIGNALS = {
    javascript: {
      disposition: BLOCK,
      label: "a script that runs when the file is opened"
    },
    launch_action: {
      disposition: BLOCK,
      label: "an instruction to run another program"
    },
    executable_attachment: {
      disposition: BLOCK,
      label: "an attached program"
    },
    embedded_file: {
      disposition: NOTE,
      label: "an attached file"
    },
    external_link: {
      disposition: NOTE,
      label: "a link to another website"
    }
  }.freeze

  class << self
    def disposition_for(signal) = SIGNALS.dig(signal, :disposition)

    def label_for(signal) = SIGNALS.dig(signal, :label)

    def blocks?(signal) = disposition_for(signal) == BLOCK

    def blocking_signals = SIGNALS.select { |_, v| v[:disposition] == BLOCK }.keys

    def noted_signals = SIGNALS.select { |_, v| v[:disposition] == NOTE }.keys

    def executable?(filename)
      extension = File.extname(filename.to_s).delete_prefix(".").downcase
      EXECUTABLE_EXTENSIONS.include?(extension)
    end
  end
end
