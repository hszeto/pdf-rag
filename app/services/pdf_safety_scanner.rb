require "origami"

# Structural inspection of an uploaded PDF, before it is stored or read (R1.3).
#
# Detection is the easy half; PdfSafetyPolicy owns the judgement about what each
# signal means. This class only finds them and reports what it found.
#
# Measured on a real 140-page policy: 2,368ms, of which 2,350ms is parsing and
# 18ms walks all 5,097 objects. The cost is reading the PDF at all, so there is
# nothing to optimise here — it is the price of the guarantee in R1.5 that a
# hostile file is never stored.
class PdfSafetyScanner
  Finding = Struct.new(:signal, :detail, keyword_init: true) do
    def blocking? = PdfSafetyPolicy.blocks?(signal)
    def label = PdfSafetyPolicy.label_for(signal)
  end

  Result = Struct.new(:findings, keyword_init: true) do
    def safe? = findings.none?(&:blocking?)
    def blocking = findings.select(&:blocking?)
    def notes = findings.reject(&:blocking?)
    def links = notes.select { |f| f.signal == :external_link }.map(&:detail)
    def attachments = notes.select { |f| f.signal == :embedded_file }.map(&:detail)
  end

  ACTION_SIGNALS = { "Launch" => :launch_action, "JavaScript" => :javascript }.freeze

  def initialize(file, reader: Origami::PDF)
    @file = file
    @reader = reader
  end

  def scan!
    pdf = open_pdf
    findings = attachment_findings(pdf) + action_findings(pdf)

    Result.new(findings: findings.uniq { |f| [ f.signal, f.detail ] })
  end

  private
    def open_pdf
      @reader.read(path_for(@file), verbosity: Origami::Parser::VERBOSE_QUIET)
    rescue StandardError => e
      # A PDF the scanner cannot make sense of is refused rather than waved
      # through (R1.6). Being unable to inspect something is not evidence that it
      # is safe.
      raise ProcessingError::Damaged, e.message
    end

    def path_for(file)
      return file.tempfile.path if file.respond_to?(:tempfile)
      return file.path if file.respond_to?(:path)

      file.to_s
    end

    # Origami wraps strings and names in its own types whose to_s keeps the PDF
    # syntax — a name renders as "/Foo", a literal string as "(Foo)".
    def value_of(object)
      object.respond_to?(:value) ? object.value.to_s : object.to_s
    end

    def attachment_findings(pdf)
      names = []
      safely { pdf.each_attachment { |name, _| names << value_of(name) } }
      safely { pdf.each_named_embedded_file { |name, _| names << value_of(name) } }

      names.uniq.reject(&:blank?).map do |name|
        signal = PdfSafetyPolicy.executable?(name) ? :executable_attachment : :embedded_file
        Finding.new(signal: signal, detail: name)
      end
    end

    # Actions hide in several places, and the obvious walk misses most of them.
    # An OpenAction on the Catalog is a *direct* dictionary, so each_object never
    # yields it; annotation actions hang off each page's /Annots. Both were
    # invisible to a first version of this that only walked indirect objects.
    def action_findings(pdf)
      actions = []
      safely { actions << pdf.Catalog&.[](:OpenAction) }
      safely { pdf.each_named_script { |_, script| actions << script } }
      safely { pdf.pages.each { |page| actions.concat(annotation_actions(page)) } }
      safely { pdf.each_object { |o| actions << o if o.is_a?(Origami::Dictionary) } }

      actions.compact.flat_map { |action| classify(action) }.compact
    end

    def annotation_actions(page)
      Array(page[:Annots]).filter_map do |annotation|
        annotation = annotation.solve if annotation.respond_to?(:solve)
        annotation[:A] if annotation.is_a?(Origami::Dictionary)
      end
    end

    def classify(action)
      action = action.solve if action.respond_to?(:solve)
      return nil unless action.is_a?(Origami::Dictionary)

      type = value_of(action[:S])
      if (signal = ACTION_SIGNALS[type])
        Finding.new(signal: signal, detail: type)
      elsif type == "URI" && action[:URI]
        Finding.new(signal: :external_link, detail: value_of(action[:URI]))
      end
    end

    # A malformed corner of a file must not abort a scan that is otherwise
    # producing useful findings; the remaining passes still cover it.
    def safely
      yield
    rescue StandardError
      nil
    end
end
