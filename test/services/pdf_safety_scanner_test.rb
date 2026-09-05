require "test_helper"

class PdfSafetyScannerTest < ActiveSupport::TestCase
  # AC 1
  test "a script that runs on open is blocking" do
    result = scan(HostilePdfs.javascript_pdf)

    assert_not result.safe?
    assert_equal [ :javascript ], result.blocking.map(&:signal)
  end

  # AC 2
  test "an instruction to run another program is blocking" do
    result = scan(HostilePdfs.launch_pdf)

    assert_not result.safe?
    assert_includes result.blocking.map(&:signal), :launch_action
  end

  # AC 3
  test "an attached program is blocking" do
    result = scan(HostilePdfs.executable_attachment_pdf(name: "payload.sh"))

    assert_not result.safe?
    assert_includes result.blocking.map(&:signal), :executable_attachment
  end

  test "every executable extension the policy lists is treated as one" do
    %w[payload.exe run.bat script.ps1 tool.jar app.py thing.vbs].each do |name|
      result = scan(HostilePdfs.executable_attachment_pdf(name: name))

      assert_includes result.blocking.map(&:signal), :executable_attachment,
        "#{name} should be treated as an attached program"
    end
  end

  # AC 4, by proxy. The real UnitedHealthcare policy carries a C2PA attachment
  # and ten links; this fixture reproduces both. A scanner that blocked on
  # either would refuse the most representative real document we have.
  test "an ordinary document with an attachment and many links is accepted" do
    result = scan(HostilePdfs.benign_document_pdf)

    assert result.safe?, "blocked by: #{result.blocking.map(&:signal).inspect}"
    assert_empty result.blocking
  end

  # D1: links never block, but they are not hidden either.
  test "links are reported so the reader can see them" do
    result = scan(HostilePdfs.benign_document_pdf)

    assert_includes result.links, "http://www.dfs.ny.gov/"
    assert_includes result.links, "mailto:UHC_Civil_Rights@uhc.com"
    assert_includes result.links, "tel:1-800-368-1019"
    assert_operator result.links.length, :>=, 8
  end

  # Genuine documents contain malformed values; that is not a reason to refuse.
  test "a malformed link does not break the scan" do
    result = scan(HostilePdfs.benign_document_pdf)

    assert result.safe?
    assert_includes result.links, "http://refer/"
  end

  # D2: a non-executable attachment is named, not blocked.
  test "an ordinary attachment is reported rather than blocked" do
    result = scan(HostilePdfs.benign_document_pdf)

    assert result.safe?
    assert_includes result.attachments, "Content Credentials"
  end

  test "a plain document produces no findings at all" do
    result = scan(HostilePdfs.plain_pdf)

    assert result.safe?
    assert_empty result.findings
  end

  # D1: OpenSSL 3 hides RC4 in a provider that is not loaded by default, so
  # before the initializer this raised ProcessingError::Damaged.
  test "a document encrypted with RC4 is read rather than refused" do
    result = scan(HostilePdfs.rc4_pdf)

    assert result.safe?
    assert_empty result.findings
  end

  test "a document encrypted with AES is read rather than refused" do
    result = scan(HostilePdfs.aes_pdf)

    assert result.safe?
    assert_empty result.findings
  end

  # R5, and the assertion that keeps D1 honest: enabling RC4 must not become a
  # way to smuggle a payload past screening. The script has to be found through
  # the encryption, which only holds because the scanner decrypts before walking.
  test "a script inside an encrypted document is still blocking" do
    result = scan(HostilePdfs.rc4_javascript_pdf)

    assert_not result.safe?
    assert_equal [ :javascript ], result.blocking.map(&:signal)
  end

  # D2: Origami prompts on STDIN for a password it cannot guess. Without
  # DECLINE_PASSWORD this test does not fail an assertion — it raises
  # Errno::EOPNOTSUPP from the terminal read, so it cannot pass by accident.
  #
  # D3: and it is locked, not damaged. Screening used to call every encrypted
  # document broken, which told the reader to fix a file that was never broken.
  test "a password-protected document is refused as locked, without prompting" do
    error = assert_raises(ProcessingError::Locked) { scan(HostilePdfs.password_protected_pdf) }

    assert_match(/password/i, error.user_message)
    assert_no_match(/damaged/i, error.user_message)
  end

  # R3: the reader never sees the parser's words, so the log has to.
  test "a refusal records why the parser gave up" do
    output = capture_log do
      assert_raises(ProcessingError::Locked) { scan(HostilePdfs.password_protected_pdf) }
    end

    assert_match(/EncryptionInvalidPasswordError/, output)
  end

  # AC 5: and none of that vocabulary reaches the reader.
  test "a refusal never mentions the machinery to the reader" do
    error = assert_raises(ProcessingError::Locked) { scan(HostilePdfs.password_protected_pdf) }

    assert_no_match(/RC4|OpenSSL|provider|Origami/i, error.user_message)
  end

  # AC 6: being unable to inspect something is not evidence it is safe.
  test "a truncated file is refused rather than waved through" do
    assert_raises(ProcessingError::Damaged) { scan(HostilePdfs.truncated_pdf) }
  end

  test "a file that is not a PDF at all is refused" do
    assert_raises(ProcessingError::Damaged) { scan(HostilePdfs.not_a_pdf) }
  end

  test "a reader that explodes is refused, not treated as clean" do
    exploding = Class.new do
      def self.read(*, **) = raise(RuntimeError, "boom")
    end

    assert_raises(ProcessingError::Damaged) do
      PdfSafetyScanner.new(HostilePdfs.plain_pdf, reader: exploding).scan!
    end
  end

  # R2.2: a refusal has to be explainable.
  test "a blocking finding carries a plain-language label" do
    finding = scan(HostilePdfs.javascript_pdf).blocking.first

    assert_equal "a script that runs when the file is opened", finding.label
  end

  private
    def scan(path) = PdfSafetyScanner.new(path).scan!

    def capture_log
      io = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = original
    end
end
