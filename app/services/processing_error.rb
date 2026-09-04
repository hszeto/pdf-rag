# Every way an upload can fail, each carrying the exact words the user sees.
#
# Keeping the copy on the error itself means controllers rescue one type and
# render one partial, which is what makes R7.5's "never a dead end" hold
# everywhere rather than at each call site that remembered to handle it.
#
# Copy avoids "upload", "AI", "session" and other technical vocabulary (R7.1).
class ProcessingError < StandardError
  def user_message = "Something went wrong. Please try again."

  # The status travels with the error for the same reason the copy does: two
  # controllers rescue this class, and neither should have to know which failure
  # deserves which code.
  def status = :unprocessable_entity

  class NotAPdf < ProcessingError
    def user_message
      "We can only read PDF files right now. Please add your document as a PDF."
    end
  end

  class TooLarge < ProcessingError
    # Derived rather than repeated: the number moved once already, and copy that
    # states a limit should not be able to disagree with the limit.
    def user_message
      "That file is too big for us to read. Please add a file smaller than " \
      "#{ActiveSupport::NumberHelper.number_to_human_size(DocumentValidator::MAX_BYTES)}."
    end
  end

  class Missing < ProcessingError
    def user_message = "We did not get a file. Please choose your document and try again."
  end

  # Asking for more than a visitor's share. Separate classes for documents and
  # questions because the windows differ, and because a log should say which
  # ceiling was reached without parsing a sentence.
  class TooManyDocuments < ProcessingError
    def user_message
      "That is a lot of documents in a short time. Please wait a little and try again."
    end

    def status = :too_many_requests
  end

  class TooManyQuestions < ProcessingError
    def user_message
      "That is a lot of questions in a short time. Please wait a little and try again."
    end

    def status = :too_many_requests
  end

  # The counter itself is unreachable, so nothing can be counted. Refusing is a
  # deliberate choice (D9): admitting the request would mean no ceiling at all,
  # and the reader would never know. 503 rather than 429 — the visitor did
  # nothing wrong, we simply cannot keep count.
  class LimiterUnavailable < ProcessingError
    def user_message
      "We cannot take that just now. Please try again in a moment."
    end

    def status = :service_unavailable
  end

  class Locked < ProcessingError
    def user_message
      "This file is locked. Please add a copy that does not need a password."
    end
  end

  class Damaged < ProcessingError
    def user_message = "We could not open this file. It may be damaged."
  end

  # A scanned or photographed document: it opens fine, but holds pictures rather
  # than words. Reading those is deferred (D3), so this is a dead end for now.
  class Unreadable < ProcessingError
    def user_message
      "We could not find any words in this document. If it is a photo or a scan, " \
      "please try a version you can select text in."
    end
  end

  # Raised when the cache write fails, so an upload never *looks* like it worked
  # and then vanishes on the next request (R3.6).
  class StorageFailure < ProcessingError
    def user_message = "We could not hold on to your document just now. Please try again."
  end

  class EmptyQuestion < ProcessingError
    def user_message = "Please type a question first."
  end

  class NoDocument < ProcessingError
    def user_message = "Please add your document first."
  end

# Structural content that asks a PDF viewer to execute something. Carries which
# signal caused the refusal, so support can answer "why was mine rejected"
# (R2.2), and so the reader is told something specific rather than "no".
class Unsafe < ProcessingError
  attr_reader :signal

  def initialize(signal)
    @signal = signal
    super("unsafe pdf: #{signal}")
  end

  def user_message
    "This PDF contains #{PdfSafetyPolicy.label_for(signal)}, so we did not open it. " \
    "Please try a different file."
  end
end

class NotReady < ProcessingError
  def user_message = "We are still reading this document. Please try again in a moment."
end

  class ServiceUnavailable < ProcessingError
    def user_message = "We are having trouble reading documents right now. Please try again in a moment."
  end

  # A daily cap, as opposed to the passing failure its parent covers. The budget
  # does not reset until tomorrow, so this stays a separate class: the two are
  # worth telling apart in logs even where the copy is deliberately close.
  #
  # The wording says neither "limit" nor "tomorrow" by choice. Why we cannot
  # answer is our problem rather than the reader's, and naming the day makes a
  # promise about when service returns that is better left unmade. A reader who
  # retries too soon simply sees this again.
  class QuotaExhausted < ServiceUnavailable
    def user_message
      "We are busier than usual today. Please try again later."
    end
  end
end
