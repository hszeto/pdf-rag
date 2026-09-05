require "origami"

# Builds the PDFs the safety tests need, rather than committing binaries.
#
# Generating them is how we know what is in them: a committed "malicious.pdf"
# is opaque, and a test asserting it gets blocked proves nothing about *why*.
# Each builder here corresponds to exactly one policy signal.
module HostilePdfs
  extend self

  def javascript_pdf = build { |pdf| add_javascript(pdf) }

  def launch_pdf = build { |pdf|
    pdf.Catalog[:OpenAction] = Origami::Action::Launch.new(
      S: Origami::Name.new("Launch"),
      F: Origami::LiteralString.new("/bin/sh")
    )
  }

  def executable_attachment_pdf(name: "payload.sh") = build { |pdf|
    attach(pdf, name, "#!/bin/sh\necho pwned")
  }

  # Stands in for the real UnitedHealthcare policy: one benign attachment and a
  # spread of ordinary links, including a malformed one, because genuine
  # documents are messy. This is a proxy, not the real file.
  def benign_document_pdf = build { |pdf|
    attach(pdf, "Content Credentials", "c2pa provenance manifest")
    page = pdf.pages.first
    [
      "http://www.dfs.ny.gov/", "https://ocrportal.hhs.gov/ocr/portal/lobby.jsf",
      "mailto:UHC_Civil_Rights@uhc.com", "tel:1-800-368-1019",
      "http://www.health.ny.gov/", "https://www.uhc.com/legal/notices",
      "http://refer/", "mailto:cha@cssny.org",
      "http://www.hhs.gov/ocr/office/file/index.html", "tel:1-800-537-7697"
    ].each_with_index do |uri, i|
      link = Origami::Annotation::Link.new
      link.Rect = Origami::Rectangle[llx: 10, lly: 10 + (i * 12), urx: 200, ury: 22 + (i * 12)]
      link.A = Origami::Action::URI.new(S: Origami::Name.new("URI"), URI: Origami::LiteralString.new(uri))
      page.add_annotation(link)
    end
  }

  def plain_pdf = build { |_pdf| }

  # Encryption is not a hostile signal — it is the thing that used to make an
  # ordinary document look damaged (D1). RC4 is what real insurer, bank and
  # government PDFs use; AES is here to show that path was never broken.
  def rc4_pdf = build { |pdf| encrypt_rc4(pdf) }

  def aes_pdf = build { |pdf| pdf.encrypt(cipher: "aes", key_size: 256) }

  # Proves screening survives D1: the script has to be found through the
  # encryption, not in spite of it.
  def rc4_javascript_pdf = build { |pdf|
    add_javascript(pdf)
    encrypt_rc4(pdf)
  }

  # Needs a password we do not have, so it can never be opened or screened.
  def password_protected_pdf = build { |pdf|
    encrypt_rc4(pdf, user_passwd: "s3cret", owner_passwd: "s3cret")
  }

  # Extraction needs genuine words, and the synthetic pages above have none, so
  # this encrypts a copy of a real fixture rather than inventing one.
  def rc4_encrypted_document(name = "insurance_sample.pdf")
    pdf = Origami::PDF.read(
      Rails.root.join("test/fixtures/files", name).to_s,
      verbosity: Origami::Parser::VERBOSE_QUIET
    )
    encrypt_rc4(pdf)
    path = tempfile_path("rc4_document")
    pdf.save(path)
    path
  end

  # Right magic header, unusable body.
  def truncated_pdf
    path = tempfile_path("truncated")
    File.binwrite(path, File.binread(plain_pdf)[0, 200])
    path
  end

  def not_a_pdf
    path = tempfile_path("jpeg")
    File.binwrite(path, "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01".b)
    path
  end

  private
    def build
      pdf = Origami::PDF.new
      pdf.append_page(Origami::Page.new)
      yield pdf
      path = tempfile_path("built")
      pdf.save(path)
      path
    end

    def add_javascript(pdf)
      pdf.Catalog[:OpenAction] = Origami::Action::JavaScript.new(
        S: Origami::Name.new("JavaScript"),
        JS: Origami::LiteralString.new("app.alert('pwned');")
      )
    end

    def encrypt_rc4(pdf, **options)
      pdf.encrypt(cipher: "rc4", key_size: 128, **options)
    end

    def attach(pdf, name, contents)
      pdf.attach_file(StringIO.new(contents), name: name)
    end

    def tempfile_path(prefix)
      file = Tempfile.new([ prefix, ".pdf" ])
      path = file.path
      file.close
      @built ||= []
      @built << file  # keep the handle so the OS does not reclaim the path
      path
    end
end
